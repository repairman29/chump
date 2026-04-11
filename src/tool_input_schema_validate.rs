//! JSON Schema validation of tool call `input` against each tool's `input_schema()` (Vector 6).

use axonerai::tool::ToolRegistry;
use axonerai::{executor::ToolResult, provider::ToolCall};
use serde_json::Value;

/// Validate `instance` against a JSON Schema value.
pub fn validate_instance(instance: &Value, schema: &Value) -> Result<(), String> {
    let validator =
        jsonschema::validator_for(schema).map_err(|e| format!("invalid tool schema: {}", e))?;
    let errs: Vec<String> = validator
        .iter_errors(instance)
        .take(12)
        .map(|e| e.to_string())
        .collect();
    if errs.is_empty() {
        Ok(())
    } else {
        Err(errs.join("; "))
    }
}

/// One entry per invalid tool call: index into `tool_calls` and a human-readable reason.
pub fn collect_schema_validation_failures(
    registry: &ToolRegistry,
    tool_calls: &[ToolCall],
) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    for (i, tc) in tool_calls.iter().enumerate() {
        match registry.get(&tc.name) {
            None => out.push((
                i,
                format!("Unknown tool '{}'. Use a registered tool name.", tc.name),
            )),
            Some(tool) => {
                let schema = tool.input_schema();
                if let Err(detail) = validate_instance(&tc.input, &schema) {
                    out.push((i, detail));
                }
            }
        }
    }
    out
}

/// Synthetic results when the batch is aborted: failed calls get schema errors; others get a skip notice.
pub fn synthetic_tool_results_for_schema_failures(
    tool_calls: &[ToolCall],
    failures: &[(usize, String)],
) -> Vec<ToolResult> {
    debug_assert!(!failures.is_empty());
    tool_calls
        .iter()
        .enumerate()
        .map(|(i, tc)| {
            let result = if let Some((_, detail)) = failures.iter().find(|(idx, _)| *idx == i) {
                format!(
                    "Tool error: Schema validation failed: {}. Please correct your JSON and try again.",
                    detail
                )
            } else {
                "Tool error: Schema validation failed: Skipped execution because a sibling tool call failed schema validation. Please correct the failed call(s) and retry."
                    .to_string()
            };
            ToolResult {
                tool_call_id: tc.id.clone(),
                tool_name: tc.name.clone(),
                result,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rejects_missing_required_field() {
        let schema = json!({
            "type": "object",
            "properties": {
                "diff": { "type": "string" },
                "path": { "type": "string" }
            },
            "required": ["diff", "path"]
        });
        let instance = json!({ "path": "x.rs" });
        let e = validate_instance(&instance, &schema).unwrap_err();
        assert!(e.to_lowercase().contains("diff") || e.contains("required"));
    }

    #[test]
    fn accepts_valid_object() {
        let schema = json!({
            "type": "object",
            "properties": { "n": { "type": "number" } },
            "required": ["n"]
        });
        validate_instance(&json!({ "n": 1.0 }), &schema).unwrap();
    }

    #[test]
    fn synthetic_marks_sibling_skipped() {
        use axonerai::provider::ToolCall;
        let calls = vec![
            ToolCall {
                id: "a".into(),
                name: "t1".into(),
                input: json!({}),
            },
            ToolCall {
                id: "b".into(),
                name: "t2".into(),
                input: json!({}),
            },
        ];
        let failures = vec![(0, "missing foo".into())];
        let out = synthetic_tool_results_for_schema_failures(&calls, &failures);
        assert!(out[0].result.contains("missing foo"));
        assert!(out[1].result.contains("Skipped execution"));
        assert_eq!(out[0].tool_call_id, "a");
        assert_eq!(out[1].tool_call_id, "b");
    }
}
