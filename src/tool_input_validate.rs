//! Pre-flight checks for tool JSON before approval/execute. Catches empty required fields early.
//! Disable with `CHUMP_SKIP_TOOL_INPUT_VALIDATE=1`.

use serde_json::Value;

#[inline]
pub fn skip_tool_input_validate() -> bool {
    crate::env_flags::env_trim_eq("CHUMP_SKIP_TOOL_INPUT_VALIDATE", "1")
}

fn non_empty_str(input: &Value, key: &str) -> bool {
    input
        .get(key)
        .and_then(Value::as_str)
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
}

/// Mirrors [`crate::cli_tool::CliTool::run`] command resolution enough to know the call would not fail on "missing command".
fn cli_like_has_command(input: &Value) -> bool {
    let cmd = input
        .get("command")
        .or_else(|| input.get("cmd"))
        .or_else(|| input.get("shell"))
        .or_else(|| input.get("script"))
        .and_then(Value::as_str)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let cmd = cmd.or_else(|| {
        let mut c = input
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if c.starts_with("run ") {
            c = c.strip_prefix("run ").unwrap_or(c).trim();
        }
        if !c.is_empty()
            && !c.contains("\"action\"")
            && (c.starts_with("cargo")
                || c.starts_with("git")
                || c.starts_with("ls")
                || c.starts_with("cat")
                || c.starts_with("pwd")
                || c.starts_with("sh ")
                || c.contains(' '))
        {
            Some(c.to_string())
        } else {
            None
        }
    });
    let cmd = cmd.or_else(|| {
        input
            .as_str()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    });
    let cmd = cmd.or_else(|| {
        input.as_object().and_then(|o| {
            for (k, v) in o {
                if k == "action" || k == "parameters" {
                    continue;
                }
                if let Some(s) = v.as_str() {
                    let s = s.trim();
                    if !s.is_empty()
                        && s.len() < 2000
                        && (s.contains(' ')
                            || s.starts_with("cargo")
                            || s.starts_with("git")
                            || s.starts_with("cat")
                            || s.starts_with("ls")
                            || s.contains('/'))
                    {
                        return Some(s.to_string());
                    }
                }
            }
            None
        })
    });
    cmd.map(|c| !c.trim().is_empty()).unwrap_or(false)
}

/// Returns `Some(reason)` when the tool call should be rejected before execution.
pub fn validate_tool_input(tool_name: &str, input: &Value) -> Option<String> {
    let name = tool_name.to_lowercase();
    match name.as_str() {
        "read_file" => {
            if !non_empty_str(input, "path") {
                Some("read_file requires non-empty \"path\" string".to_string())
            } else {
                None
            }
        }
        "write_file" => {
            if !non_empty_str(input, "path") {
                Some("write_file requires non-empty \"path\" string".to_string())
            } else if !input.get("content").is_some_and(|v| v.is_string()) {
                Some("write_file requires string \"content\"".to_string())
            } else {
                None
            }
        }
        "edit_file" => {
            if !non_empty_str(input, "path") {
                Some("edit_file requires non-empty \"path\" string".to_string())
            } else if !input.get("old_str").is_some_and(Value::is_string) {
                Some("edit_file requires string \"old_str\"".to_string())
            } else if !input.get("new_str").is_some_and(Value::is_string) {
                Some("edit_file requires string \"new_str\"".to_string())
            } else {
                None
            }
        }
        "list_dir" => None,
        "read_url" => {
            if !non_empty_str(input, "url") {
                Some("read_url requires non-empty \"url\" string".to_string())
            } else {
                None
            }
        }
        "web_search" => {
            if !non_empty_str(input, "query") {
                Some("web_search requires non-empty \"query\" string".to_string())
            } else {
                None
            }
        }
        "run_cli" | "git" | "cargo" => {
            if cli_like_has_command(input) {
                None
            } else {
                Some(
                    "missing command (expected non-empty command/cmd/shell/script, content with a shell command, a JSON string body, or a suitable string field)"
                        .to_string(),
                )
            }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{validate_tool_input, cli_like_has_command};
    use serde_json::json;

    #[test]
    fn read_file_requires_path() {
        assert!(validate_tool_input("read_file", &json!({})).is_some());
        assert!(validate_tool_input("read_file", &json!({"path": ""})).is_some());
        assert!(validate_tool_input("read_file", &json!({"path": "x"})).is_none());
    }

    #[test]
    fn write_file_requires_path_and_string_content() {
        assert!(validate_tool_input("write_file", &json!({"path": "p"})).is_some());
        assert!(validate_tool_input("write_file", &json!({"path": "p", "content": 1})).is_some());
        assert!(validate_tool_input("write_file", &json!({"path": "p", "content": ""})).is_none());
    }

    #[test]
    fn cli_accepts_command_key() {
        assert!(cli_like_has_command(&json!({"command": "ls"})));
        assert!(!cli_like_has_command(&json!({"command": ""})));
        assert!(!cli_like_has_command(&json!({})));
    }
}
