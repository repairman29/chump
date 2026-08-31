//! decompose_task: orchestrator tool to break a task into independent subtasks (disjoint files).
//! Single completion via cascade; returns JSON array of { description, files_to_modify, branch_name, test_command }.
//!
//! COTG-0.3 (vision -> MVP scope negotiation): each subtask also carries a
//! `phase` (1 = the smallest honest first tool; 2+ = negotiated-but-deferred
//! follow-on work). `execute()` returns only phase-1 subtasks — the rest are
//! recorded (persisted to the linked outcome's `deferred_phases`, when an
//! `outcome_id` is supplied) but never handed to spawn_worker. This guards
//! the overbuild failure mode: later phases exist on paper, not in flight.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::provider::Message;
use axonerai::tool::Tool;
use serde_json::{json, Value};

use crate::provider_cascade;

const DECOMPOSE_SYSTEM_PROMPT: &str = r#"Given the codebase digest and task description, decompose into independent subtasks.
Each subtask must touch a disjoint set of files (no two subtasks edit the same file).
Output only a valid JSON array of objects. Each object must have:
- "description": string (what to do)
- "files_to_modify": array of strings (file paths, disjoint across subtasks)
- "branch_name": string (e.g. chump/task-1-subtask-1)
- "test_command": string (e.g. "cargo test" or "npm test")
- "depends_on": array of integers (0-based indices of subtasks that must finish first; empty [] if independent)
- "phase": integer (1 = the smallest honest first version that delivers real value;
  2+ = a real but deliberately deferred follow-on phase, negotiated now and recorded,
  not started). Most tasks are phase 1. Only mark phase 2+ when the full task is
  over-broad for a first version — the phase-1 subset must stand alone as usable.
Order subtasks so independent ones appear first. Express dependencies via the depends_on field.
Output nothing else except the JSON array."#;

fn extract_json_array(text: &str) -> Result<Value> {
    let trimmed = text.trim();
    let start = trimmed
        .find('[')
        .ok_or_else(|| anyhow!("no '[' in response"))?;
    let end = trimmed
        .rfind(']')
        .ok_or_else(|| anyhow!("no ']' in response"))?;
    let slice = trimmed
        .get(start..=end)
        .ok_or_else(|| anyhow!("slice failed"))?;
    let parsed = serde_json::from_str::<Value>(slice)?;
    if parsed.is_array() {
        Ok(parsed)
    } else {
        Err(anyhow!("parsed value is not an array"))
    }
}

/// A subtask is phase 1 (the MVP slice) unless it explicitly declares a
/// later phase. Missing/non-numeric `phase` defaults to 1 so pre-COTG-0.3
/// model output (no `phase` field) stays fully backward compatible.
fn subtask_phase(subtask: &Value) -> i64 {
    subtask
        .get("phase")
        .and_then(|v| v.as_i64())
        .filter(|p| *p >= 1)
        .unwrap_or(1)
}

/// Split decomposed subtasks into the MVP slice (phase 1, returned to the
/// caller for spawn_worker) and the negotiated-but-deferred remainder
/// (phase > 1, recorded but never started). The MVP slice is always a
/// strict subset of the full array whenever any subtask declares phase > 1.
fn partition_by_phase(subtasks: &Value) -> (Vec<Value>, Vec<Value>) {
    let items = subtasks.as_array().cloned().unwrap_or_default();
    let mut mvp = Vec::new();
    let mut deferred = Vec::new();
    for item in items {
        if subtask_phase(&item) <= 1 {
            mvp.push(item);
        } else {
            deferred.push(item);
        }
    }
    (mvp, deferred)
}

pub struct DecomposeTaskTool;

#[async_trait]
impl Tool for DecomposeTaskTool {
    fn name(&self) -> String {
        "decompose_task".to_string()
    }

    fn description(&self) -> String {
        "Decompose a task into independent subtasks (disjoint files). Params: task (string), codebase_digest (string), outcome_id (optional string). Returns JSON array of phase-1 (MVP) { description, files_to_modify[], branch_name, test_command, phase } subtasks only — any negotiated phase-2+ follow-on work is recorded against outcome_id (when supplied), not returned. Use before spawn_worker.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "task": { "type": "string", "description": "Task description" },
                "codebase_digest": { "type": "string", "description": "Codebase digest (e.g. from codebase_digest tool or chump-brain digest)" },
                "repo": { "type": "string", "description": "Optional repo name for branch prefix" },
                "outcome_id": { "type": "string", "description": "Optional outcome ID (see `chump outcome list`) to record any phase-2+ deferred subtasks against" }
            },
            "required": ["task", "codebase_digest"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let task = input
            .get("task")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing task"))?
            .trim();
        let digest = input
            .get("codebase_digest")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing codebase_digest"))?
            .trim();
        let _repo = input
            .get("repo")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty());
        let outcome_id = input
            .get("outcome_id")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty());

        let user_content = format!(
            "Task:\n{}\n\nCodebase digest:\n{}\n\nOutput the JSON array of subtasks.",
            task, digest
        );
        let messages = vec![Message {
            role: "user".to_string(),
            content: user_content,
        }];
        let provider = provider_cascade::build_provider();
        let response = provider
            .complete(
                messages,
                None,
                Some(4096),
                Some(DECOMPOSE_SYSTEM_PROMPT.to_string()),
            )
            .await?;
        let text = response
            .text
            .unwrap_or_else(|| "".to_string())
            .trim()
            .to_string();
        if text.is_empty() {
            return Err(anyhow!("empty response from model"));
        }
        let parsed = extract_json_array(&text).or_else(|e| {
            let retry = text
                .replace("```json", "")
                .replace("```", "")
                .trim()
                .to_string();
            extract_json_array(&retry).map_err(|_| anyhow!("parse failed: {}; raw: {}", e, text))
        })?;

        let (mvp, deferred) = partition_by_phase(&parsed);
        if let Some(oid) = outcome_id {
            if !deferred.is_empty() {
                if let Err(e) = persist_deferred_phases(oid, &deferred) {
                    // Advisory persistence, mirroring the rest of the outcomes
                    // table (CLAUDE.md: outcome rollup never gates a gap) — a
                    // storage hiccup here must not block the MVP slice from
                    // reaching spawn_worker.
                    eprintln!(
                        "decompose_task: failed to record deferred phases for outcome {oid}: {e:#}"
                    );
                }
            }
        }

        Ok(Value::Array(mvp).to_string())
    }
}

/// Persist the negotiated-but-deferred phase-2+ subtasks against `outcome_id`
/// (COTG-0.3 AC2: "later phases are recorded but not started").
fn persist_deferred_phases(outcome_id: &str, deferred: &[Value]) -> Result<()> {
    let repo_root = crate::repo_path::repo_root();
    let store = crate::gap_store::GapStore::open(&repo_root)?;
    let phases_json = Value::Array(deferred.to_vec()).to_string();
    store.record_deferred_phases(outcome_id, &phases_json)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn subtask(desc: &str, phase: Option<i64>) -> Value {
        let mut v = json!({
            "description": desc,
            "files_to_modify": [format!("src/{desc}.rs")],
            "branch_name": format!("chump/{desc}"),
            "test_command": "cargo test",
            "depends_on": [],
        });
        if let Some(p) = phase {
            v["phase"] = json!(p);
        }
        v
    }

    #[test]
    fn extract_json_array_finds_bracketed_slice_amid_prose() {
        let text = "Sure, here it is:\n[{\"a\":1}]\nHope that helps!";
        let parsed = extract_json_array(text).unwrap();
        assert_eq!(parsed, json!([{"a": 1}]));
    }

    #[test]
    fn extract_json_array_rejects_non_array_json() {
        assert!(extract_json_array("{\"a\":1}").is_err());
    }

    #[test]
    fn subtask_phase_defaults_to_1_when_field_missing() {
        // Pre-COTG-0.3 model output has no "phase" field at all — must still
        // behave as an MVP-phase subtask, not silently vanish.
        assert_eq!(subtask_phase(&subtask("legacy", None)), 1);
    }

    #[test]
    fn subtask_phase_rejects_non_positive_values() {
        assert_eq!(subtask_phase(&subtask("zero", Some(0))), 1);
        assert_eq!(subtask_phase(&subtask("negative", Some(-1))), 1);
    }

    #[test]
    fn partition_by_phase_splits_mvp_from_deferred() {
        let subtasks = json!([
            subtask("warn-before-overspend", Some(1)),
            subtask("receipt-scanning", Some(2)),
            subtask("no-phase-field", None),
        ]);
        let (mvp, deferred) = partition_by_phase(&subtasks);
        assert_eq!(mvp.len(), 2);
        assert_eq!(deferred.len(), 1);
        assert_eq!(deferred[0]["description"], "receipt-scanning");
    }

    /// COTG-0.3 AC3: an over-broad vision is narrowed to an MVP whose scope
    /// is provably a strict subset of the full decomposition.
    #[test]
    fn mvp_slice_is_a_strict_subset_of_the_full_decomposition() {
        let full = json!([
            subtask("core-budget-warning", Some(1)),
            subtask("receipt-scanning", Some(2)),
            subtask("multi-currency-support", Some(3)),
        ]);
        let (mvp, deferred) = partition_by_phase(&full);
        let full_len = full.as_array().unwrap().len();
        assert!(mvp.len() < full_len, "MVP slice must be a strict subset");
        assert_eq!(mvp.len() + deferred.len(), full_len);
        assert_eq!(mvp[0]["description"], "core-budget-warning");
    }

    #[test]
    fn persist_deferred_phases_round_trips_through_the_outcome_row() {
        let dir = tempfile::tempdir().unwrap();
        let repo_root = dir.path();
        let store = crate::gap_store::GapStore::open(repo_root).unwrap();
        store
            .create_outcome("COTG-TEST-1", "test outcome", "P2", "done when shipped")
            .unwrap();

        let deferred = vec![subtask("receipt-scanning", Some(2))];
        let phases_json = Value::Array(deferred.clone()).to_string();
        store
            .record_deferred_phases("COTG-TEST-1", &phases_json)
            .unwrap();

        let row = store.get_outcome("COTG-TEST-1").unwrap().unwrap();
        let persisted: Value =
            serde_json::from_str(&row.deferred_phases.expect("deferred_phases set")).unwrap();
        assert_eq!(persisted, Value::Array(deferred));
    }

    #[test]
    fn persist_deferred_phases_errs_on_unknown_outcome() {
        let dir = tempfile::tempdir().unwrap();
        let store = crate::gap_store::GapStore::open(dir.path()).unwrap();
        let err = store.record_deferred_phases("NO-SUCH-OUTCOME", "[]");
        assert!(err.is_err());
    }
}
