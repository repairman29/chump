//! Runtime assertion framework for gap execution — fail-fast validation.
//! CREDIBLE-065: catch data invariant violations early with clear error messages.

use serde_json::Value;

/// AssertionError encapsulates a failed assertion with context for debugging.
#[derive(Debug, Clone)]
pub struct AssertionError {
    /// What the assertion was checking
    pub assertion_type: String,
    /// Which field/key failed
    pub field_name: String,
    /// What we expected
    pub expected: String,
    /// What we actually found
    pub actual: String,
    /// Optional extended context
    pub context: String,
}

impl std::fmt::Display for AssertionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}: field '{}' expected '{}' but got '{}'{}",
            self.assertion_type,
            self.field_name,
            self.expected,
            self.actual,
            if self.context.is_empty() {
                String::new()
            } else {
                format!(" ({})", self.context)
            }
        )
    }
}

impl std::error::Error for AssertionError {}

/// Result type for assertions
pub type AssertionResult<T> = Result<T, AssertionError>;

/// assert_json_shape verifies that a JSON object contains all required fields
/// with the correct types.
///
/// # Arguments
///
/// * `json_obj` - The JSON value to check (should be an object)
/// * `required_fields` - Map of field_name -> expected_type (e.g. "string", "object", "array")
///
/// # Example
///
/// ```ignore
/// let gap_json = json!({ "id": "INFRA-1", "status": "open" });
/// assert_json_shape(&gap_json, &[("id", "string"), ("status", "string")])?;
/// ```
pub fn assert_json_shape(
    json_obj: &Value,
    required_fields: &[(&str, &str)],
) -> AssertionResult<()> {
    if !json_obj.is_object() {
        return Err(AssertionError {
            assertion_type: "json_shape".to_string(),
            field_name: "[root]".to_string(),
            expected: "object".to_string(),
            actual: json_obj.type_str().to_string(),
            context: String::new(),
        });
    }

    let obj = json_obj.as_object().unwrap();

    for (field_name, expected_type) in required_fields {
        let field_value = obj.get(*field_name);

        let actual_type = match field_value {
            Some(v) => v.type_str(),
            None => "missing",
        };

        if field_value.is_none() || !actual_type.eq_ignore_ascii_case(expected_type) {
            return Err(AssertionError {
                assertion_type: "json_shape".to_string(),
                field_name: field_name.to_string(),
                expected: expected_type.to_string(),
                actual: actual_type.to_string(),
                context: format!("required field missing or wrong type in JSON object"),
            });
        }
    }

    Ok(())
}

/// assert_gap_valid checks that a gap record has all required fields and valid content.
///
/// # Arguments
///
/// * `gap_data` - A JSON object representing a gap (typically from state.db)
///
/// # Returns
///
/// Ok(()) if valid, or AssertionError with field name and expected/actual values
pub fn assert_gap_valid(gap_data: &Value) -> AssertionResult<()> {
    // Required top-level gap fields
    let required = vec![
        ("id", "string"),
        ("domain", "string"),
        ("title", "string"),
        ("status", "string"),
        ("priority", "string"),
    ];

    assert_json_shape(gap_data, &required)?;

    // Additional validation: status must be one of the valid values
    if let Some(status_val) = gap_data.get("status").and_then(|v| v.as_str()) {
        let valid_statuses = vec!["open", "claimed", "done", "wontfix"];
        if !valid_statuses.contains(&status_val) {
            return Err(AssertionError {
                assertion_type: "gap_valid".to_string(),
                field_name: "status".to_string(),
                expected: format!("one of: {}", valid_statuses.join(", ")),
                actual: status_val.to_string(),
                context: String::new(),
            });
        }
    }

    // priority must be P0, P1, P2, or P3
    if let Some(priority_val) = gap_data.get("priority").and_then(|v| v.as_str()) {
        let valid_priorities = vec!["P0", "P1", "P2", "P3"];
        if !valid_priorities.contains(&priority_val) {
            return Err(AssertionError {
                assertion_type: "gap_valid".to_string(),
                field_name: "priority".to_string(),
                expected: format!("one of: {}", valid_priorities.join(", ")),
                actual: priority_val.to_string(),
                context: String::new(),
            });
        }
    }

    // Observability: gap validation passed
    if let Some(gap_id) = gap_data.get("id").and_then(|v| v.as_str()) {
        eprintln!(
            "[assertion] gap_valid: {} — status={} priority={}",
            gap_id,
            gap_data
                .get("status")
                .and_then(|v| v.as_str())
                .unwrap_or("?"),
            gap_data
                .get("priority")
                .and_then(|v| v.as_str())
                .unwrap_or("?")
        );
    }

    Ok(())
}

/// assert_lease_held verifies that a lease JSON has the required structure and valid data.
///
/// # Arguments
///
/// * `lease_data` - A JSON object representing a gap claim lease
///
/// # Returns
///
/// Ok(()) if the lease is structurally valid
pub fn assert_lease_held(lease_data: &Value) -> AssertionResult<()> {
    let required = vec![
        ("gap_id", "string"),
        ("session_id", "string"),
        ("claimed_at", "number"),
        ("worktree_path", "string"),
    ];

    assert_json_shape(lease_data, &required)?;

    // Verify claimed_at is a reasonable timestamp (after 2020)
    if let Some(claimed_at) = lease_data.get("claimed_at").and_then(|v| v.as_i64()) {
        let min_timestamp = 1577836800i64; // Jan 1, 2020 in seconds
        if claimed_at < min_timestamp {
            return Err(AssertionError {
                assertion_type: "lease_held".to_string(),
                field_name: "claimed_at".to_string(),
                expected: format!("> {}", min_timestamp),
                actual: claimed_at.to_string(),
                context: "timestamp must be after 2020".to_string(),
            });
        }
    }

    // Observability: lease validation passed
    if let Some(gap_id) = lease_data.get("gap_id").and_then(|v| v.as_str()) {
        if let Some(session_id) = lease_data.get("session_id").and_then(|v| v.as_str()) {
            eprintln!(
                "[assertion] lease_held: {} session={} valid",
                gap_id, session_id
            );
        }
    }

    Ok(())
}

/// Helper trait for JSON types
trait JsonTypeExt {
    fn type_str(&self) -> &'static str;
}

impl JsonTypeExt for Value {
    fn type_str(&self) -> &'static str {
        match self {
            Value::Null => "null",
            Value::Bool(_) => "boolean",
            Value::Number(_) => "number",
            Value::String(_) => "string",
            Value::Array(_) => "array",
            Value::Object(_) => "object",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_assert_json_shape_valid() {
        let json = json!({
            "id": "INFRA-1",
            "title": "Test",
            "status": "open"
        });
        let result = assert_json_shape(&json, &[("id", "string"), ("title", "string")]);
        assert!(result.is_ok());
    }

    #[test]
    fn test_assert_json_shape_missing_field() {
        let json = json!({ "id": "INFRA-1" });
        let result = assert_json_shape(&json, &[("id", "string"), ("title", "string")]);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.field_name, "title");
        assert_eq!(err.actual, "missing");
    }

    #[test]
    fn test_assert_json_shape_wrong_type() {
        let json = json!({
            "id": 123,
            "title": "Test"
        });
        let result = assert_json_shape(&json, &[("id", "string")]);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.field_name, "id");
        assert_eq!(err.expected, "string");
        assert_eq!(err.actual, "number");
    }

    #[test]
    fn test_assert_gap_valid_full() {
        let gap = json!({
            "id": "INFRA-1",
            "domain": "INFRA",
            "title": "Test gap",
            "status": "open",
            "priority": "P1"
        });
        assert!(assert_gap_valid(&gap).is_ok());
    }

    #[test]
    fn test_assert_gap_valid_invalid_status() {
        let gap = json!({
            "id": "INFRA-1",
            "domain": "INFRA",
            "title": "Test gap",
            "status": "invalid",
            "priority": "P1"
        });
        let result = assert_gap_valid(&gap);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.field_name, "status");
    }

    #[test]
    fn test_assert_gap_valid_invalid_priority() {
        let gap = json!({
            "id": "INFRA-1",
            "domain": "INFRA",
            "title": "Test gap",
            "status": "open",
            "priority": "P5"
        });
        let result = assert_gap_valid(&gap);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.field_name, "priority");
    }

    #[test]
    fn test_assert_lease_held_valid() {
        let lease = json!({
            "gap_id": "INFRA-1",
            "session_id": "sess-123",
            "claimed_at": 1700000000i64,
            "worktree_path": "/tmp/chump-infra-1"
        });
        assert!(assert_lease_held(&lease).is_ok());
    }

    #[test]
    fn test_assert_lease_held_invalid_timestamp() {
        let lease = json!({
            "gap_id": "INFRA-1",
            "session_id": "sess-123",
            "claimed_at": 1000000i64,
            "worktree_path": "/tmp/chump-infra-1"
        });
        let result = assert_lease_held(&lease);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.field_name, "claimed_at");
    }

    #[test]
    fn test_assertion_error_display() {
        let err = AssertionError {
            assertion_type: "json_shape".to_string(),
            field_name: "id".to_string(),
            expected: "string".to_string(),
            actual: "number".to_string(),
            context: "top-level field".to_string(),
        };
        let display = format!("{}", err);
        assert!(display.contains("json_shape"));
        assert!(display.contains("id"));
        assert!(display.contains("string"));
        assert!(display.contains("number"));
    }
}
