//! CREDIBLE-065: runtime assertion framework for gap execution — fail-fast validation.
//!
//! Provides data-invariant helpers used at key boundaries (gap claim, gap ship).
//! When an assertion fires it:
//!   1. Emits `kind=assertion_failure` to ambient.jsonl (so fleet-brief + watchdogs see it).
//!   2. Returns `Err` so the caller surfaces a clear, actionable error message.
//!
//! See `docs/ASSERTIONS.md` for the full catalog and failure recovery guide.

use anyhow::{anyhow, Result};

// ── Ambient event helpers ────────────────────────────────────────────────────

/// Emit `kind=assertion_failure` to ambient.jsonl. Best-effort: if the emit
/// fails (e.g. disk full, misconfigured repo root) we log to stderr and continue
/// rather than masking the original assertion error.
pub fn emit_assertion_failure(assertion_name: &str, expected: &str, actual: &str) {
    let args = crate::ambient_emit::EmitArgs {
        kind: "assertion_failure".to_string(),
        source: Some("src/assertion.rs".to_string()),
        fields: vec![
            ("assertion".to_string(), assertion_name.to_string()),
            ("expected".to_string(), expected.to_string()),
            ("actual".to_string(), actual.to_string()),
        ],
        ..Default::default()
    };
    if let Err(e) = crate::ambient_emit::emit(&args) {
        eprintln!("[assertion] warn: could not emit assertion_failure event: {e}");
    }
}

// ── assert_json_shape ────────────────────────────────────────────────────────

/// Assert that `value` is a JSON object containing all `required_keys`.
pub fn assert_json_shape(value: &serde_json::Value, required_keys: &[&str]) -> Result<()> {
    let obj = value.as_object().ok_or_else(|| {
        anyhow!(
            "assertion failed (assert_json_shape): expected JSON object, got {}",
            value
        )
    })?;
    let missing: Vec<&str> = required_keys
        .iter()
        .filter(|k| !obj.contains_key(**k))
        .copied()
        .collect();
    if !missing.is_empty() {
        emit_assertion_failure(
            "assert_json_shape",
            &format!("{required_keys:?}"),
            &format!("missing keys: {missing:?}"),
        );
        return Err(anyhow!(
            "assertion failed (assert_json_shape): missing keys {missing:?}"
        ));
    }
    Ok(())
}

// ── assert_gap_valid ─────────────────────────────────────────────────────────

/// Assert that a GapRow has a non-empty id, non-empty title, and at least one
/// non-vague acceptance criterion (not all TODO/TBD). Used in `chump gap claim`.
pub fn assert_gap_valid(gap: &chump_gap_store::GapRow) -> Result<()> {
    if gap.id.is_empty() {
        emit_assertion_failure("assert_gap_valid", "non-empty gap.id", "empty string");
        return Err(anyhow!(
            "assertion failed (assert_gap_valid): gap.id is empty"
        ));
    }
    if gap.title.is_empty() {
        emit_assertion_failure(
            "assert_gap_valid",
            "non-empty gap.title",
            &format!("empty title for gap {}", gap.id),
        );
        return Err(anyhow!(
            "assertion failed (assert_gap_valid): gap.title is empty for {}",
            gap.id
        ));
    }
    if is_acceptance_criteria_vague(&gap.acceptance_criteria) {
        emit_assertion_failure(
            "assert_gap_valid",
            "at least 1 concrete acceptance criterion",
            &format!("vague/empty ACs for gap {}", gap.id),
        );
        return Err(anyhow!(
            "assertion failed (assert_gap_valid): gap {} has no concrete acceptance_criteria",
            gap.id
        ));
    }
    Ok(())
}

/// Mirror of `is_acceptance_criteria_vague` from main.rs (INFRA-1259).
fn is_acceptance_criteria_vague(ac: &str) -> bool {
    let trimmed = ac.trim();
    if trimmed.is_empty() {
        return true;
    }
    if let Ok(serde_json::Value::Array(arr)) = serde_json::from_str(trimmed) {
        if arr.is_empty() {
            return true;
        }
        return arr.iter().all(|item| {
            if let Some(s) = item.as_str() {
                let up = s.to_uppercase();
                up == "TODO"
                    || up == "TBD"
                    || up.contains("TODO")
                    || up.contains("TBD")
                    || up.contains("<FILL IN>")
            } else {
                false
            }
        });
    }
    let up = trimmed.to_uppercase();
    up == "TODO" || up == "TBD" || up == "[]"
}

// ── assert_lease_held ────────────────────────────────────────────────────────

/// Assert that an active lease file exists for `gap_id` in `repo_root/.chump-locks/`.
/// Used in `chump gap ship` as a soft warning (not hard exit).
pub fn assert_lease_held(gap_id: &str, repo_root: &std::path::Path) -> Result<()> {
    let lock_dir = repo_root.join(".chump-locks");
    let held = std::fs::read_dir(&lock_dir)
        .ok()
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok())
        .any(|entry| {
            let name = entry.file_name();
            let s = name.to_string_lossy();
            if !s.ends_with(".json") || s.starts_with('.') {
                return false;
            }
            std::fs::read_to_string(entry.path())
                .map(|contents| contents.contains(gap_id))
                .unwrap_or(false)
        });
    if !held {
        emit_assertion_failure(
            "assert_lease_held",
            &format!("active lease for {gap_id}"),
            "no lease file found",
        );
        return Err(anyhow!(
            "assertion failed (assert_lease_held): no active lease for {gap_id} in {}",
            lock_dir.display()
        ));
    }
    Ok(())
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // Helper: build a minimal valid GapRow (GapRow has no Default impl).
    fn make_gap(id: &str, title: &str, ac: &str) -> chump_gap_store::GapRow {
        chump_gap_store::GapRow {
            id: id.to_string(),
            domain: "INFRA".to_string(),
            title: title.to_string(),
            description: String::new(),
            priority: "P1".to_string(),
            effort: "s".to_string(),
            status: "open".to_string(),
            acceptance_criteria: ac.to_string(),
            depends_on: "[]".to_string(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: 0,
            closed_at: None,
            opened_date: String::new(),
            closed_date: String::new(),
            closed_pr: None,
            skills_required: String::new(),
            preferred_backend: String::new(),
            preferred_machine: String::new(),
            estimated_minutes: String::new(),
            required_model: String::new(),
        }
    }

    #[test]
    fn json_shape_passes_when_all_keys_present() {
        let v = serde_json::json!({"a": 1, "b": "hello", "c": null});
        assert!(assert_json_shape(&v, &["a", "b"]).is_ok());
    }

    #[test]
    fn json_shape_fails_with_missing_key() {
        let v = serde_json::json!({"a": 1});
        let err = assert_json_shape(&v, &["a", "missing_key"]).unwrap_err();
        assert!(err.to_string().contains("missing keys"));
        assert!(err.to_string().contains("missing_key"));
    }

    #[test]
    fn json_shape_fails_on_non_object() {
        let v = serde_json::json!([1, 2, 3]);
        let err = assert_json_shape(&v, &["x"]).unwrap_err();
        assert!(err.to_string().contains("expected JSON object"));
    }

    #[test]
    fn gap_valid_passes_with_concrete_ac() {
        let gap = make_gap(
            "INFRA-999",
            "EFFECTIVE: test gap",
            r#"["do the thing","verify the thing"]"#,
        );
        assert!(assert_gap_valid(&gap).is_ok());
    }

    #[test]
    fn gap_valid_fails_on_empty_id() {
        let gap = make_gap("", "some title", r#"["ac"]"#);
        let err = assert_gap_valid(&gap).unwrap_err();
        assert!(err.to_string().contains("gap.id is empty"));
    }

    #[test]
    fn gap_valid_fails_on_todo_ac() {
        let gap = make_gap("INFRA-1", "title", r#"["TODO: fill this in","TBD"]"#);
        let err = assert_gap_valid(&gap).unwrap_err();
        assert!(err.to_string().contains("concrete acceptance_criteria"));
    }

    #[test]
    fn lease_held_false_on_missing_dir() {
        let tmp = std::path::PathBuf::from("/tmp/assertion-test-no-such-repo-98765");
        let err = assert_lease_held("INFRA-999", &tmp).unwrap_err();
        assert!(err.to_string().contains("no active lease"));
    }

    #[test]
    fn lease_held_true_when_file_contains_gap_id() {
        use std::io::Write;
        let tmp = tempfile::tempdir().unwrap();
        let lock_dir = tmp.path().join(".chump-locks");
        std::fs::create_dir_all(&lock_dir).unwrap();
        let mut f = std::fs::File::create(lock_dir.join("claim-infra-999-test.json")).unwrap();
        writeln!(f, r#"{{"gap_id":"INFRA-999","session":"test"}}"#).unwrap();
        assert!(assert_lease_held("INFRA-999", tmp.path()).is_ok());
    }

    #[test]
    fn ac_vague_detection_todo() {
        assert!(is_acceptance_criteria_vague(r#"["TODO: something"]"#));
    }

    #[test]
    fn ac_vague_detection_empty_array() {
        assert!(is_acceptance_criteria_vague("[]"));
    }

    #[test]
    fn ac_not_vague_with_concrete_ac() {
        assert!(!is_acceptance_criteria_vague(
            r#"["Deploy the widget","Verify CI passes"]"#
        ));
    }
}
