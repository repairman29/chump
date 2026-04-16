//! `fleet` tool — agent-facing interface for multi-agent fleet coordination.
//!
//! Phase 3.1 of the Hermes competitive roadmap. Wraps [`crate::fleet`] and
//! [`crate::fleet_db`] with action-based dispatch (mirrors [`crate::checkpoint_tool`]).
//!
//! Actions:
//!   - `register`      — register the current peer (role + capabilities)
//!   - `list`          — list all known peers with status
//!   - `dispatch`      — send work to a peer (by id, role, or capabilities)
//!   - `status`        — show detailed status for a single peer
//!   - `propose_merge` — record a workspace merge proposal (V1: no execution)
//!   - `heartbeat`     — bump current peer's last_seen timestamp
//!
//! V1 is a scaffold: dispatches are recorded but not executed against remote peers,
//! and merge proposals are persisted-as-intent only. Cross-peer transport lands in V2.

use crate::fleet::{
    self, FleetDispatchRequest, FleetPeer, MemoryAttribution, PeerStatus, WorkspaceMergeProposal,
};
use crate::fleet_db;
use anyhow::Result;
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct FleetTool;

impl FleetTool {
    pub fn new() -> Self {
        Self
    }
}

impl Default for FleetTool {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Tool for FleetTool {
    fn name(&self) -> String {
        "fleet".to_string()
    }

    fn description(&self) -> String {
        "Coordinate with other agents in a multi-peer fleet (Phase 3.1 scaffold). \
         Actions: register (announce this peer with its role and capabilities), \
         list (show all known peers and their status), \
         dispatch (send a task to a specific peer or any peer matching role/capabilities — \
         V1 records intent only, no remote execution), \
         status (detailed info for one peer by id), \
         propose_merge (start a workspace merge proposal — V1 records the proposal, \
         no state transfer), \
         heartbeat (refresh this peer's last_seen timestamp). \
         Current peer id comes from CHUMP_FLEET_PEER_ID env var or the host's hostname."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["register", "list", "dispatch", "status", "propose_merge", "heartbeat"],
                    "description": "Action to perform"
                },
                "peer_id": {
                    "type": "string",
                    "description": "Peer id (required for status; optional for dispatch as 'to_peer')."
                },
                "role": {
                    "type": "string",
                    "description": "Role for register (e.g. 'builder', 'sentinel'), or required role for dispatch."
                },
                "capabilities": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Capabilities for register, or required capabilities for dispatch."
                },
                "endpoint": {
                    "type": "string",
                    "description": "Optional HTTP endpoint for register."
                },
                "task": {
                    "type": "string",
                    "description": "Task description for dispatch."
                },
                "priority": {
                    "type": "number",
                    "description": "Dispatch priority (default 0; higher runs sooner)."
                },
                "participants": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Peer ids participating in propose_merge."
                },
                "objective": {
                    "type": "string",
                    "description": "Shared objective for propose_merge."
                },
                "duration_turns": {
                    "type": "number",
                    "description": "How many turns the merge lasts (propose_merge)."
                },
                "memory_attribution": {
                    "type": "string",
                    "enum": ["all", "initiator", "none"],
                    "description": "Memory attribution mode for propose_merge (default 'all')."
                },
                "metadata_json": {
                    "type": "string",
                    "description": "Free-form JSON metadata for register."
                },
                "status": {
                    "type": "string",
                    "enum": ["online", "busy", "offline", "unknown"],
                    "description": "Initial status for register (default 'online')."
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
            _ => return Ok("fleet needs an object with 'action'.".to_string()),
        };
        let action = obj
            .get("action")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        match action {
            "register" => handle_register(obj),
            "list" => handle_list(),
            "dispatch" => handle_dispatch(obj),
            "status" => handle_status(obj),
            "propose_merge" => handle_propose_merge(obj),
            "heartbeat" => handle_heartbeat(),
            "" => Ok(
                "fleet requires 'action' (register | list | dispatch | status | propose_merge | heartbeat)."
                    .to_string(),
            ),
            other => Ok(format!(
                "Unknown action '{}'. Valid: register, list, dispatch, status, propose_merge, heartbeat.",
                other
            )),
        }
    }
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn caps_from_obj(obj: &serde_json::Map<String, Value>) -> Vec<String> {
    obj.get("capabilities")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

fn handle_register(obj: &serde_json::Map<String, Value>) -> Result<String> {
    let peer_id = obj
        .get("peer_id")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(fleet::current_peer_id);
    let role = obj
        .get("role")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "generalist".to_string());
    let capabilities = caps_from_obj(obj);
    let endpoint = obj
        .get("endpoint")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let metadata_json = obj
        .get("metadata_json")
        .and_then(|v| v.as_str())
        .unwrap_or("{}")
        .to_string();
    let status = obj
        .get("status")
        .and_then(|v| v.as_str())
        .map(PeerStatus::from_str)
        .unwrap_or(PeerStatus::Online);

    let peer = FleetPeer {
        peer_id: peer_id.clone(),
        role: role.clone(),
        capabilities: capabilities.clone(),
        endpoint,
        status,
        last_seen_unix: now_unix(),
        metadata_json,
    };
    fleet::register_peer(peer)?;
    Ok(format!(
        "Registered peer '{}' as '{}' with capabilities {:?} (status={}).",
        peer_id,
        role,
        capabilities,
        status.as_str()
    ))
}

fn handle_list() -> Result<String> {
    let peers = fleet::list_peers()?;
    if peers.is_empty() {
        return Ok("No peers registered. Use action=register to add one.".to_string());
    }
    let mut lines = vec![format!("{} peer(s):", peers.len())];
    for p in peers {
        lines.push(format!(
            "  [{}] role={} status={} caps={:?} last_seen={}",
            p.peer_id,
            p.role,
            p.status.as_str(),
            p.capabilities,
            p.last_seen_unix
        ));
    }
    Ok(lines.join("\n"))
}

fn handle_dispatch(obj: &serde_json::Map<String, Value>) -> Result<String> {
    let task = match obj.get("task").and_then(|v| v.as_str()) {
        Some(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => return Ok("dispatch requires 'task' (non-empty string).".to_string()),
    };
    let to_peer = obj
        .get("peer_id")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let required_role = obj
        .get("role")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let required_capabilities = caps_from_obj(obj);
    let priority = obj
        .get("priority")
        .and_then(|v| v.as_u64())
        .unwrap_or(0) as u32;
    let from_peer = fleet::current_peer_id();
    let req = FleetDispatchRequest {
        from_peer: from_peer.clone(),
        to_peer: to_peer.clone(),
        required_role,
        required_capabilities,
        task_description: task.clone(),
        priority,
        deadline_unix: None,
    };
    let matched = fleet::find_peer_for_task(&req)?;
    let target_id = matched.as_ref().map(|p| p.peer_id.clone());
    let dispatch_id = fleet_db::record_dispatch(
        &from_peer,
        target_id.as_deref().or(to_peer.as_deref()),
        &task,
        priority,
    )?;
    match matched {
        Some(p) => Ok(format!(
            "Dispatch #{} recorded: '{}' -> peer '{}' (role={}, status={}). \
             V1 records intent only — remote execution lands in V2.",
            dispatch_id,
            task,
            p.peer_id,
            p.role,
            p.status.as_str()
        )),
        None => Ok(format!(
            "Dispatch #{} recorded with no matching peer found. Task: '{}'. \
             V1 stores the request for later assignment.",
            dispatch_id, task
        )),
    }
}

fn handle_status(obj: &serde_json::Map<String, Value>) -> Result<String> {
    let peer_id = match obj.get("peer_id").and_then(|v| v.as_str()) {
        Some(s) if !s.trim().is_empty() => s.trim().to_string(),
        _ => return Ok("status requires 'peer_id'.".to_string()),
    };
    match fleet::get_peer(&peer_id)? {
        Some(p) => Ok(format!(
            "Peer '{}': role={}, status={}, capabilities={:?}, endpoint={:?}, \
             last_seen_unix={}, metadata={}",
            p.peer_id,
            p.role,
            p.status.as_str(),
            p.capabilities,
            p.endpoint,
            p.last_seen_unix,
            p.metadata_json
        )),
        None => Ok(format!("No peer '{}' registered.", peer_id)),
    }
}

fn handle_propose_merge(obj: &serde_json::Map<String, Value>) -> Result<String> {
    let participants: Vec<String> = obj
        .get("participants")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();
    if participants.is_empty() {
        return Ok("propose_merge requires non-empty 'participants' array.".to_string());
    }
    let objective = match obj.get("objective").and_then(|v| v.as_str()) {
        Some(s) if !s.trim().is_empty() => s.trim().to_string(),
        _ => return Ok("propose_merge requires 'objective' (non-empty string).".to_string()),
    };
    let duration_turns = obj
        .get("duration_turns")
        .and_then(|v| v.as_u64())
        .unwrap_or(1) as u32;
    let memory_attribution = match obj
        .get("memory_attribution")
        .and_then(|v| v.as_str())
        .unwrap_or("all")
        .to_ascii_lowercase()
        .as_str()
    {
        "initiator" => MemoryAttribution::Initiator,
        "none" => MemoryAttribution::None,
        _ => MemoryAttribution::AllParticipants,
    };
    let initiator = fleet::current_peer_id();
    let merge_id = format!("merge-{}-{}", initiator, now_unix());
    let proposal = WorkspaceMergeProposal {
        merge_id: merge_id.clone(),
        initiator: initiator.clone(),
        participants: participants.clone(),
        shared_objective: objective.clone(),
        duration_turns,
        memory_attribution,
    };
    // V1: persist as a dispatch row tagged with the proposal JSON. Full state-transfer
    // protocol lands in V2.
    let payload = serde_json::to_string(&proposal).unwrap_or_default();
    let task = format!("[workspace_merge_proposal] {}", payload);
    let row = fleet_db::record_dispatch(&initiator, None, &task, 0)?;
    Ok(format!(
        "Workspace merge proposed (id='{}', dispatch_row={}): initiator='{}', participants={:?}, \
         objective='{}', duration_turns={}, memory={:?}. \
         V1 records the proposal — actual state transfer lands in V2.",
        merge_id, row, initiator, participants, objective, duration_turns, memory_attribution
    ))
}

fn handle_heartbeat() -> Result<String> {
    let peer_id = fleet::current_peer_id();
    fleet::heartbeat(&peer_id)?;
    Ok(format!("Heartbeat recorded for peer '{}'.", peer_id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fleet::PeerStatus;

    fn unique(tag: &str) -> String {
        format!(
            "test-fleet-tool-{}-{}-{}",
            tag,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        )
    }

    #[test]
    fn schema_validates() {
        let tool = FleetTool::new();
        let schema = tool.input_schema();
        assert!(schema.get("properties").is_some());
        assert!(schema
            .get("required")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().any(|v| v.as_str() == Some("action")))
            .unwrap_or(false));
    }

    #[tokio::test]
    async fn unknown_action_returns_error_message() {
        let tool = FleetTool::new();
        let result = tool.execute(json!({ "action": "nope" })).await.unwrap();
        assert!(result.contains("Unknown action"));
    }

    #[tokio::test]
    async fn missing_action_returns_helpful_message() {
        let tool = FleetTool::new();
        let result = tool.execute(json!({})).await.unwrap();
        assert!(result.contains("requires 'action'"));
    }

    #[tokio::test]
    async fn register_list_unregister_cycle() {
        let id = unique("cycle");
        let tool = FleetTool::new();

        let reg = tool
            .execute(json!({
                "action": "register",
                "peer_id": id,
                "role": "builder",
                "capabilities": ["rust", "git"],
                "status": "online"
            }))
            .await
            .unwrap();
        assert!(reg.contains("Registered peer"));

        let listed = tool.execute(json!({ "action": "list" })).await.unwrap();
        assert!(listed.contains(&id));

        // Verify status action
        let st = tool
            .execute(json!({ "action": "status", "peer_id": id }))
            .await
            .unwrap();
        assert!(st.contains("role=builder"));

        // Cleanup
        crate::fleet::unregister_peer(&id).unwrap();
        assert!(crate::fleet::get_peer(&id).unwrap().is_none());
    }

    #[tokio::test]
    async fn dispatch_matches_by_role_and_capability() {
        let id = unique("dispatch-match");
        let peer = FleetPeer {
            peer_id: id.clone(),
            role: "specialist".to_string(),
            capabilities: vec!["docker".to_string(), "termux".to_string()],
            endpoint: None,
            status: PeerStatus::Online,
            last_seen_unix: 1_700_000_000,
            metadata_json: "{}".to_string(),
        };
        crate::fleet::register_peer(peer).unwrap();

        let tool = FleetTool::new();
        let out = tool
            .execute(json!({
                "action": "dispatch",
                "role": "specialist",
                "capabilities": ["docker"],
                "task": "build container"
            }))
            .await
            .unwrap();
        assert!(out.contains(&id), "expected matched peer id in output: {}", out);

        crate::fleet::unregister_peer(&id).unwrap();
    }

    #[tokio::test]
    async fn dispatch_without_match_still_records() {
        let tool = FleetTool::new();
        let out = tool
            .execute(json!({
                "action": "dispatch",
                "role": "no-such-role-xyzzy",
                "task": "do something"
            }))
            .await
            .unwrap();
        assert!(out.contains("Dispatch #"));
    }

    #[tokio::test]
    async fn dispatch_requires_task() {
        let tool = FleetTool::new();
        let out = tool.execute(json!({ "action": "dispatch" })).await.unwrap();
        assert!(out.contains("'task'"));
    }

    #[tokio::test]
    async fn status_requires_peer_id() {
        let tool = FleetTool::new();
        let out = tool.execute(json!({ "action": "status" })).await.unwrap();
        assert!(out.contains("'peer_id'"));
    }

    #[tokio::test]
    async fn propose_merge_records_proposal() {
        let tool = FleetTool::new();
        let out = tool
            .execute(json!({
                "action": "propose_merge",
                "participants": ["alpha", "beta"],
                "objective": "joint refactor",
                "duration_turns": 5,
                "memory_attribution": "all"
            }))
            .await
            .unwrap();
        assert!(out.contains("Workspace merge proposed"));
    }

    #[tokio::test]
    async fn propose_merge_requires_participants() {
        let tool = FleetTool::new();
        let out = tool
            .execute(json!({ "action": "propose_merge", "objective": "x" }))
            .await
            .unwrap();
        assert!(out.contains("participants"));
    }

    #[tokio::test]
    async fn heartbeat_returns_confirmation() {
        let id = unique("heartbeat");
        // Need a peer registered for heartbeat to actually update something, but heartbeat
        // tool reads current_peer_id, so register that.
        std::env::set_var("CHUMP_FLEET_PEER_ID", &id);
        crate::fleet::register_peer(FleetPeer {
            peer_id: id.clone(),
            role: "builder".to_string(),
            capabilities: vec![],
            endpoint: None,
            status: PeerStatus::Online,
            last_seen_unix: 0,
            metadata_json: "{}".to_string(),
        })
        .unwrap();
        let tool = FleetTool::new();
        let out = tool.execute(json!({ "action": "heartbeat" })).await.unwrap();
        assert!(out.contains("Heartbeat recorded"));
        crate::fleet::unregister_peer(&id).unwrap();
        std::env::remove_var("CHUMP_FLEET_PEER_ID");
    }
}
