//! Pending peer (Mabel) approval for tools in CHUMP_PEER_APPROVE_TOOLS.
//! Chump writes request_id/tool_name/tool_input to brain/a2a/pending_approval.json so Mabel
//! can read it in her Verify round, run tests, and call POST /api/approve. Clear on resolve.

use std::collections::HashSet;

use crate::context_assembly;

const PENDING_FILE: &str = "a2a/pending_approval.json";

/// Comma-separated tool names that can be approved by the peer (e.g. git_push, merge_pr).
pub fn peer_approve_tools() -> HashSet<String> {
    std::env::var("CHUMP_PEER_APPROVE_TOOLS")
        .ok()
        .map(|s| {
            s.split(',')
                .map(|t| t.trim().to_lowercase())
                .filter(|t| !t.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// Write pending approval to brain so Mabel can see it. Call when emitting ToolApprovalRequest for a tool in CHUMP_PEER_APPROVE_TOOLS.
pub fn write_pending_peer_approval(request_id: &str, tool_name: &str, tool_input: &serde_json::Value) {
    let Ok(brain) = context_assembly::brain_root() else { return };
    let path = brain.join(PENDING_FILE);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let payload = serde_json::json!({
        "request_id": request_id,
        "tool_name": tool_name,
        "tool_input": tool_input,
    });
    let _ = std::fs::write(path, payload.to_string());
}

/// Clear pending file when this request_id is resolved. Call from resolve_approval after sending the oneshot.
pub fn clear_pending_peer_approval(request_id: &str) {
    let Ok(brain) = context_assembly::brain_root() else { return };
    let path = brain.join(PENDING_FILE);
    let Ok(data) = std::fs::read_to_string(&path) else { return };
    let Ok(obj) = serde_json::from_str::<serde_json::Value>(&data) else { return };
    let Some(id) = obj.get("request_id").and_then(|v| v.as_str()) else { return };
    if id == request_id {
        let _ = std::fs::remove_file(&path);
    }
}
