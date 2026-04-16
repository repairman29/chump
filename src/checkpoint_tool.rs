//! `checkpoint` tool — agent-facing interface for conversation rollback checkpoints.
//!
//! Phase 1.6 of the Hermes roadmap. Wraps [`crate::checkpoint_db`] with action-based
//! dispatch (mirrors the [`crate::skill_tool::SkillManageTool`] pattern).
//!
//! Actions:
//!   - `create <name> [notes]` — snapshot the current session
//!   - `list`                  — list checkpoints for the current session
//!   - `rollback <id>`         — V1 scaffold: record intent only (no state revert yet)
//!   - `delete <id>`           — remove a checkpoint
//!
//! Session id comes from [`crate::agent_session::active_session_id`].

use crate::checkpoint_db;
use anyhow::Result;
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct CheckpointTool;

impl CheckpointTool {
    pub fn new() -> Self {
        Self
    }
}

impl Default for CheckpointTool {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Tool for CheckpointTool {
    fn name(&self) -> String {
        "checkpoint".to_string()
    }

    fn description(&self) -> String {
        "Save, list, and roll back conversation checkpoints for the current session. \
         Actions: create (snapshot the session under a name, with optional notes), \
         list (show all checkpoints for the current session, newest first), \
         rollback (V1 scaffold — records intent; actual session reversion lands in V2), \
         delete (remove a checkpoint by id). Session id is inferred from the active \
         session context; calling outside an active session returns a helpful error."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["create", "list", "rollback", "delete"],
                    "description": "Action to perform"
                },
                "name": {
                    "type": "string",
                    "description": "Checkpoint name. Required for create."
                },
                "id": {
                    "type": "number",
                    "description": "Checkpoint id. Required for rollback and delete."
                },
                "notes": {
                    "type": "string",
                    "description": "Optional free-form notes attached to the checkpoint (used by create; rollback also appends rollback intent here)."
                }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(msg) = crate::limits::check_tool_input_len(&input) {
            return Ok(msg);
        }
        let obj = match &input {
            Value::Object(m) => m,
            _ => return Ok("checkpoint needs an object with 'action'.".to_string()),
        };
        let action = obj
            .get("action")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        match action {
            "create" => handle_create(obj),
            "list" => handle_list(),
            "rollback" => handle_rollback(obj),
            "delete" => handle_delete(obj),
            "" => {
                Ok("checkpoint requires 'action' (create | list | rollback | delete).".to_string())
            }
            other => Ok(format!(
                "Unknown action '{}'. Valid: create, list, rollback, delete.",
                other
            )),
        }
    }
}

fn current_session_id() -> Result<String, String> {
    crate::agent_session::active_session_id().ok_or_else(|| {
        "No active session — checkpoint tool needs a session context. \
         (Call from inside an agent turn, or set the active session id first.)"
            .to_string()
    })
}

fn handle_create(obj: &serde_json::Map<String, Value>) -> Result<String> {
    let session_id = match current_session_id() {
        Ok(s) => s,
        Err(msg) => return Ok(msg),
    };
    let name = match obj.get("name").and_then(|v| v.as_str()) {
        Some(n) if !n.trim().is_empty() => n.trim().to_string(),
        _ => return Ok("create requires 'name' (non-empty string).".to_string()),
    };
    let notes = obj
        .get("notes")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    // V1 does not snapshot the live session state — that's V2 work.
    let id = checkpoint_db::create_checkpoint(&session_id, &name, 0, None, notes.as_deref())?;
    Ok(format!(
        "Created checkpoint '{}' (id {}) for session {}. State snapshot reconstruction is V2 work — V1 records metadata only.",
        name, id, session_id
    ))
}

fn handle_list() -> Result<String> {
    let session_id = match current_session_id() {
        Ok(s) => s,
        Err(msg) => return Ok(msg),
    };
    let checkpoints = checkpoint_db::list_checkpoints(&session_id)?;
    if checkpoints.is_empty() {
        return Ok(format!(
            "No checkpoints for session {}. Use action=create to add one.",
            session_id
        ));
    }
    let mut lines = vec![format!(
        "{} checkpoints for session {}:",
        checkpoints.len(),
        session_id
    )];
    for c in checkpoints {
        let note_suffix = match c.notes.as_deref() {
            Some(n) if !n.is_empty() => format!(" — {}", n),
            _ => String::new(),
        };
        lines.push(format!(
            "  [{}] {} (msgs={}, at {}){}",
            c.id, c.name, c.message_count, c.created_at, note_suffix
        ));
    }
    Ok(lines.join("\n"))
}

fn handle_rollback(obj: &serde_json::Map<String, Value>) -> Result<String> {
    let id = match obj.get("id").and_then(|v| v.as_i64()) {
        Some(n) => n,
        None => return Ok("rollback requires 'id' (number).".to_string()),
    };
    let cp = match checkpoint_db::get_checkpoint(id)? {
        Some(c) => c,
        None => return Ok(format!("No checkpoint with id {} found.", id)),
    };
    // V1 scaffold: append rollback intent to notes so the next session can act on it.
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let intent = format!("[rollback-requested ts={}]", stamp);
    let new_notes = match cp.notes.as_deref() {
        Some(n) if !n.is_empty() => format!("{}\n{}", n, intent),
        _ => intent,
    };
    let conn = crate::db_pool::get()?;
    conn.execute(
        "UPDATE chump_checkpoints SET notes = ?1 WHERE id = ?2",
        rusqlite::params![new_notes, id],
    )?;
    Ok(format!(
        "Rollback requested — will take effect on next session. Checkpoint id {} ('{}') noted. \
         (V1 records intent only; full session-state revert lands in V2.)",
        id, cp.name
    ))
}

fn handle_delete(obj: &serde_json::Map<String, Value>) -> Result<String> {
    let id = match obj.get("id").and_then(|v| v.as_i64()) {
        Some(n) => n,
        None => return Ok("delete requires 'id' (number).".to_string()),
    };
    let existed = checkpoint_db::get_checkpoint(id)?.is_some();
    checkpoint_db::delete_checkpoint(id)?;
    if existed {
        Ok(format!("Deleted checkpoint id {}.", id))
    } else {
        Ok(format!("No checkpoint with id {} (nothing to delete).", id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_validates() {
        let tool = CheckpointTool::new();
        let schema = tool.input_schema();
        assert!(schema.get("properties").is_some());
        assert!(schema
            .get("required")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().any(|v| v.as_str() == Some("action")))
            .unwrap_or(false));
        let props = schema.get("properties").unwrap();
        for k in ["action", "name", "id", "notes"] {
            assert!(props.get(k).is_some(), "schema missing property {}", k);
        }
    }

    #[tokio::test]
    async fn unknown_action_returns_error_message() {
        let tool = CheckpointTool::new();
        let result = tool.execute(json!({ "action": "nope" })).await.unwrap();
        assert!(result.contains("Unknown action"));
    }

    #[tokio::test]
    async fn missing_action_returns_helpful_message() {
        let tool = CheckpointTool::new();
        let result = tool.execute(json!({})).await.unwrap();
        assert!(result.contains("requires 'action'"));
    }

    #[tokio::test]
    async fn create_without_session_returns_helpful_error() {
        // Ensure no active session in this thread.
        crate::agent_session::set_active_session_id(None);
        let tool = CheckpointTool::new();
        let result = tool
            .execute(json!({ "action": "create", "name": "x" }))
            .await
            .unwrap();
        assert!(result.contains("No active session"), "got: {}", result);
    }

    #[tokio::test]
    async fn create_without_name_errors() {
        crate::agent_session::set_active_session_id(Some("test-cp-tool-create-noname"));
        let tool = CheckpointTool::new();
        let result = tool.execute(json!({ "action": "create" })).await.unwrap();
        assert!(result.contains("'name'"), "got: {}", result);
        crate::agent_session::set_active_session_id(None);
    }

    #[tokio::test]
    async fn rollback_requires_id() {
        let tool = CheckpointTool::new();
        let result = tool.execute(json!({ "action": "rollback" })).await.unwrap();
        assert!(result.contains("'id'"), "got: {}", result);
    }

    #[tokio::test]
    async fn delete_requires_id() {
        let tool = CheckpointTool::new();
        let result = tool.execute(json!({ "action": "delete" })).await.unwrap();
        assert!(result.contains("'id'"), "got: {}", result);
    }

    #[tokio::test]
    async fn full_create_list_rollback_delete_cycle() {
        let session = format!(
            "test-cp-tool-cycle-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        );
        crate::agent_session::set_active_session_id(Some(&session));
        let tool = CheckpointTool::new();

        // create
        let create_out = tool
            .execute(json!({
                "action": "create",
                "name": "checkpoint-alpha",
                "notes": "before risky refactor"
            }))
            .await
            .unwrap();
        assert!(create_out.contains("Created checkpoint"));

        // list
        let list_out = tool.execute(json!({ "action": "list" })).await.unwrap();
        assert!(list_out.contains("checkpoint-alpha"));

        // pull the id back so we can rollback/delete
        let cp = checkpoint_db::checkpoint_by_name(&session, "checkpoint-alpha")
            .unwrap()
            .expect("checkpoint exists");

        // rollback (scaffold)
        let rb_out = tool
            .execute(json!({ "action": "rollback", "id": cp.id }))
            .await
            .unwrap();
        assert!(rb_out.contains("Rollback requested"));
        let after_rb = checkpoint_db::get_checkpoint(cp.id).unwrap().unwrap();
        assert!(after_rb
            .notes
            .as_deref()
            .map(|n| n.contains("rollback-requested"))
            .unwrap_or(false));

        // delete
        let del_out = tool
            .execute(json!({ "action": "delete", "id": cp.id }))
            .await
            .unwrap();
        assert!(del_out.contains("Deleted checkpoint"));
        assert!(checkpoint_db::get_checkpoint(cp.id).unwrap().is_none());

        crate::agent_session::set_active_session_id(None);
    }
}
