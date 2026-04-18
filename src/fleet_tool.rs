//! `fleet` tool — agent-facing interface for multi-agent fleet coordination.
//!
//! Phase 3.1 / FLEET-003b. Wraps [`crate::fleet`] and [`crate::fleet_db`] with
//! action-based dispatch (mirrors [`crate::checkpoint_tool`]).
//!
//! Actions:
//!   - `register`           — register the current peer (role + capabilities)
//!   - `list`               — list all known peers with status
//!   - `dispatch`           — send work to a peer (by id, role, or capabilities)
//!   - `status`             — show detailed status for a single peer
//!   - `propose_merge`      — record a workspace merge proposal (V1: no execution)
//!   - `heartbeat`          — bump current peer's last_seen timestamp
//!   - `exchange_workspace` — atomically swap blackboard snapshots with a peer
//!   - `merge_workspace`    — initiate a bounded merge session with a peer (FLEET-003c)
//!   - `split_workspace`    — end an active merge session (FLEET-003c)
//!
//! V1 is a scaffold: dispatches are recorded but not executed against remote peers,
//! and merge proposals are persisted-as-intent only.
//! FLEET-003b: `exchange_workspace` is a live HTTP round-trip — requires the peer's
//! `endpoint` to be registered.
//! FLEET-003c: `merge_workspace` initiates a bounded merge (calls exchange_workspace +
//! sets merge state); `split_workspace` ends it. Both enforce a high-risk approval gate.
//!
//! ## Merge approval gate
//! Merging exposes your blackboard to a remote peer. Gate: either
//! `CHUMP_FLEET_MERGE_APPROVE=1` (bypass) or `"fleet_merge"` in `CHUMP_TOOLS_ASK`
//! (approval UI fires upstream). Without either, the action is refused.

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
        "Coordinate with other agents in a multi-peer fleet (FLEET-003b). \
         Actions: register (announce this peer with its role and capabilities), \
         list (show all known peers and their status), \
         dispatch (send a task to a specific peer or any peer matching role/capabilities — \
         V1 records intent only, no remote execution), \
         status (detailed info for one peer by id), \
         propose_merge (start a workspace merge proposal — V1 records the proposal, \
         no state transfer), \
         heartbeat (refresh this peer's last_seen timestamp), \
         exchange_workspace (FLEET-003b: atomically swap high-salience blackboard snapshots \
         with a named peer — requires peer to have an endpoint registered; items received \
         from peer are attributed with 'peer:<peer_id>' source). \
         Current peer id comes from CHUMP_FLEET_PEER_ID env var or the host's hostname."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["register", "list", "dispatch", "status", "propose_merge", "heartbeat", "exchange_workspace", "merge_workspace", "split_workspace"],
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
                },
                "duration": {
                    "type": "number",
                    "description": "Merge duration in turns for merge_workspace (default 3, max 10)."
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
            "exchange_workspace" => handle_exchange_workspace(obj).await,
            "merge_workspace" => handle_merge_workspace(obj).await,
            "split_workspace" => handle_split_workspace(),
            "" => Ok(
                "fleet requires 'action' (register | list | dispatch | status | propose_merge | heartbeat | exchange_workspace | merge_workspace | split_workspace)."
                    .to_string(),
            ),
            other => Ok(format!(
                "Unknown action '{}'. Valid: register, list, dispatch, status, propose_merge, heartbeat, exchange_workspace, merge_workspace, split_workspace.",
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
    let priority = obj.get("priority").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
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

// ── FLEET-003c: merge / split gate ───────────────────────────────────────────

/// Check the high-risk approval gate for merge/split actions.
/// Gate: `CHUMP_FLEET_MERGE_APPROVE=1` (bypass) OR `"fleet_merge"` in `CHUMP_TOOLS_ASK`.
fn check_merge_gate() -> Result<(), String> {
    if std::env::var("CHUMP_FLEET_MERGE_APPROVE")
        .map(|v| v == "1" || v.to_lowercase() == "true")
        .unwrap_or(false)
    {
        return Ok(());
    }
    let ask = std::env::var("CHUMP_TOOLS_ASK").unwrap_or_default();
    if ask
        .split(',')
        .any(|t| t.trim().eq_ignore_ascii_case("fleet_merge"))
    {
        return Ok(());
    }
    Err(
        "merge_workspace / split_workspace require explicit approval because merging \
         exposes your blackboard to a remote peer.\n\
         Either:\n\
         • Set CHUMP_FLEET_MERGE_APPROVE=1 to bypass (no UI), OR\n\
         • Add 'fleet_merge' to CHUMP_TOOLS_ASK so the approval UI fires before each call."
            .to_string(),
    )
}

// ── FLEET-003c: merge_workspace ───────────────────────────────────────────────

/// FLEET-003c: initiate a bounded workspace merge with a remote peer.
///
/// Required: `peer_id`
/// Optional: `duration` (turns, default 3, capped at 10), `endpoint` override.
///
/// Steps:
///   1. Check merge approval gate.
///   2. Resolve peer endpoint.
///   3. Call `exchange_workspace` to swap blackboards right now.
///   4. Set the global merge state so `fleet::merge_attribution_tag()` is non-None
///      for the next `duration` agent turns.
async fn handle_merge_workspace(obj: &serde_json::Map<String, Value>) -> Result<String> {
    if let Err(msg) = check_merge_gate() {
        return Ok(msg);
    }
    let peer_id = match obj.get("peer_id").and_then(|v| v.as_str()) {
        Some(s) if !s.trim().is_empty() => s.trim().to_string(),
        _ => return Ok("merge_workspace requires 'peer_id'.".to_string()),
    };
    let duration_turns = obj
        .get("duration")
        .and_then(|v| v.as_u64())
        .map(|d| d.clamp(1, 10) as u32)
        .unwrap_or(3);

    // Resolve endpoint: explicit override or registry.
    let endpoint = if let Some(ep) = obj
        .get("endpoint")
        .and_then(|v| v.as_str())
        .filter(|s| !s.trim().is_empty())
    {
        ep.to_string()
    } else {
        match fleet::get_peer(&peer_id)? {
            Some(p) => match p.endpoint {
                Some(ep) => ep,
                None => {
                    return Ok(format!(
                        "merge_workspace: peer '{}' has no endpoint registered. \
                         Add an endpoint via action=register to enable live exchange.",
                        peer_id
                    ))
                }
            },
            None => {
                return Ok(format!(
                    "merge_workspace: no peer '{}' registered.",
                    peer_id
                ))
            }
        }
    };

    let my_id = fleet::current_peer_id();
    let my_bb = fleet::snapshot_local_blackboard(&my_id);
    let sent_count = my_bb.items.len();

    // Exchange blackboards.
    match fleet::exchange_workspace(&peer_id, my_bb, &endpoint).await {
        Ok(peer_bb) => {
            let recv_count = peer_bb.items.len();
            // Set global merge state — from this point, episodes/lessons will be tagged.
            let session_id = fleet::start_merge(&peer_id, duration_turns);
            Ok(format!(
                "merge_workspace: exchange complete. Sent {} item(s), received {} item(s) \
                 from peer '{}'.\nMerge session '{}' active for {} turn(s) — all episodes \
                 and lessons created in this window will be tagged 'merged_with:{}'.\n\
                 Run split_workspace to end early.",
                sent_count, recv_count, peer_id, session_id, duration_turns, peer_id,
            ))
        }
        Err(e) => Ok(format!(
            "merge_workspace: exchange with peer '{}' failed (merge NOT started): {}",
            peer_id, e
        )),
    }
}

// ── FLEET-003c: split_workspace ───────────────────────────────────────────────

/// FLEET-003c: end the current workspace merge session.
fn handle_split_workspace() -> Result<String> {
    if let Err(msg) = check_merge_gate() {
        return Ok(msg);
    }
    match fleet::end_merge() {
        Some(state) => Ok(format!(
            "split_workspace: merge session '{}' with peer '{}' ended \
             (was active since turn {}, duration_turns={}).\n\
             Attribution tag 'merged_with:{}' is now inactive.",
            state.merge_session_id,
            state.peer_id,
            state.start_turn,
            state.duration_turns,
            state.peer_id,
        )),
        None => Ok("split_workspace: no active merge session to end.".to_string()),
    }
}

/// FLEET-003b: atomically exchange blackboard snapshots with a remote peer.
///
/// Required inputs:
///   - `peer_id` — the peer to exchange with; must be registered with an endpoint.
///
/// Optional:
///   - `endpoint` — override the peer's registered endpoint (e.g. for testing).
async fn handle_exchange_workspace(obj: &serde_json::Map<String, Value>) -> Result<String> {
    let peer_id = match obj.get("peer_id").and_then(|v| v.as_str()) {
        Some(s) if !s.trim().is_empty() => s.trim().to_string(),
        _ => return Ok("exchange_workspace requires 'peer_id'.".to_string()),
    };

    // Resolve peer endpoint: explicit override first, then registry lookup.
    let endpoint = if let Some(ep) = obj
        .get("endpoint")
        .and_then(|v| v.as_str())
        .filter(|s| !s.trim().is_empty())
    {
        ep.to_string()
    } else {
        match fleet::get_peer(&peer_id)? {
            Some(p) => match p.endpoint {
                Some(ep) => ep,
                None => {
                    return Ok(format!(
                        "exchange_workspace: peer '{}' is registered but has no endpoint. \
                         Register with an endpoint to enable live exchange.",
                        peer_id
                    ))
                }
            },
            None => {
                return Ok(format!(
                    "exchange_workspace: no peer '{}' registered. Use action=register first.",
                    peer_id
                ))
            }
        }
    };

    let my_id = fleet::current_peer_id();
    let my_bb = fleet::snapshot_local_blackboard(&my_id);
    let my_item_count = my_bb.items.len();

    match fleet::exchange_workspace(&peer_id, my_bb, &endpoint).await {
        Ok(peer_bb) => Ok(format!(
            "exchange_workspace: sent {} item(s) to peer '{}', received {} item(s). \
             Peer seq={}. All items ingested with attribution 'peer:{}'.",
            my_item_count,
            peer_id,
            peer_bb.items.len(),
            peer_bb.sequence,
            peer_id,
        )),
        Err(e) => Ok(format!(
            "exchange_workspace with peer '{}' failed: {}",
            peer_id, e
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fleet::PeerStatus;
    use serial_test::serial;

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
        assert!(
            out.contains(&id),
            "expected matched peer id in output: {}",
            out
        );

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

    // ── FLEET-003b: exchange_workspace tests ─────────────────────────────────

    // ── FLEET-003c: merge / split tests ─────────────────────────────────────
    // NOTE: tests that mutate the global ACTIVE_MERGE state are marked #[serial]
    // to prevent parallel test runs from interfering with each other.

    #[tokio::test]
    #[serial]
    async fn merge_workspace_requires_approval_gate() {
        std::env::remove_var("CHUMP_FLEET_MERGE_APPROVE");
        std::env::remove_var("CHUMP_TOOLS_ASK");
        let tool = FleetTool::new();
        let out = tool
            .execute(json!({
                "action": "merge_workspace",
                "peer_id": "mabel"
            }))
            .await
            .unwrap();
        assert!(
            out.contains("CHUMP_FLEET_MERGE_APPROVE") || out.contains("approval"),
            "expected gate message, got: {}",
            out
        );
    }

    #[tokio::test]
    #[serial]
    async fn merge_workspace_requires_peer_id() {
        std::env::set_var("CHUMP_FLEET_MERGE_APPROVE", "1");
        let tool = FleetTool::new();
        let out = tool
            .execute(json!({ "action": "merge_workspace" }))
            .await
            .unwrap();
        std::env::remove_var("CHUMP_FLEET_MERGE_APPROVE");
        assert!(out.contains("peer_id"), "got: {}", out);
    }

    #[tokio::test]
    #[serial]
    async fn merge_workspace_unregistered_peer_gives_clear_message() {
        std::env::set_var("CHUMP_FLEET_MERGE_APPROVE", "1");
        let tool = FleetTool::new();
        let out = tool
            .execute(json!({
                "action": "merge_workspace",
                "peer_id": "ghost-peer-xyzzy-99999"
            }))
            .await
            .unwrap();
        std::env::remove_var("CHUMP_FLEET_MERGE_APPROVE");
        assert!(
            out.contains("no peer") || out.contains("registered"),
            "got: {}",
            out
        );
    }

    #[tokio::test]
    #[serial]
    async fn merge_workspace_unreachable_endpoint_returns_error_no_merge_started() {
        std::env::set_var("CHUMP_FLEET_MERGE_APPROVE", "1");
        // Clear any stale merge state from previous tests.
        crate::fleet::end_merge();
        let tool = FleetTool::new();
        let out = tool
            .execute(json!({
                "action": "merge_workspace",
                "peer_id": "unreachable-peer",
                "endpoint": "http://127.0.0.1:19998"
            }))
            .await
            .unwrap();
        std::env::remove_var("CHUMP_FLEET_MERGE_APPROVE");
        // Exchange failed → merge should NOT be active.
        assert!(
            crate::fleet::active_merge_peer().is_none(),
            "merge should not be active after failed exchange"
        );
        assert!(
            out.contains("failed") || out.contains("NOT started"),
            "expected failure message, got: {}",
            out
        );
    }

    #[test]
    #[serial]
    fn split_workspace_requires_approval_gate() {
        std::env::remove_var("CHUMP_FLEET_MERGE_APPROVE");
        std::env::remove_var("CHUMP_TOOLS_ASK");
        let result = handle_split_workspace();
        let out = result.unwrap();
        assert!(
            out.contains("CHUMP_FLEET_MERGE_APPROVE") || out.contains("approval"),
            "expected gate message, got: {}",
            out
        );
    }

    #[test]
    #[serial]
    fn split_workspace_no_active_merge() {
        std::env::set_var("CHUMP_FLEET_MERGE_APPROVE", "1");
        // Ensure no merge is active.
        crate::fleet::end_merge();
        let out = handle_split_workspace().unwrap();
        std::env::remove_var("CHUMP_FLEET_MERGE_APPROVE");
        assert!(out.contains("no active merge"), "got: {}", out);
    }

    #[test]
    #[serial]
    fn start_and_split_merge_lifecycle() {
        std::env::set_var("CHUMP_FLEET_MERGE_APPROVE", "1");
        crate::fleet::end_merge(); // clean slate
                                   // Start a merge.
        let session_id = crate::fleet::start_merge("pixel-mabel", 3);
        assert!(!session_id.is_empty());
        assert_eq!(
            crate::fleet::active_merge_peer().as_deref(),
            Some("pixel-mabel")
        );
        // Split it.
        let out = handle_split_workspace().unwrap();
        std::env::remove_var("CHUMP_FLEET_MERGE_APPROVE");
        assert!(out.contains("pixel-mabel"), "got: {}", out);
        assert!(
            out.contains(&session_id),
            "session id should appear in split message"
        );
        assert!(crate::fleet::active_merge_peer().is_none());
    }

    #[test]
    #[serial]
    fn merge_attribution_tag_injected_into_episodes() {
        crate::fleet::end_merge();
        let _session = crate::fleet::start_merge("attr-test-peer", 5);
        // The tag should be active.
        let tag = crate::fleet::merge_attribution_tag();
        assert_eq!(tag.as_deref(), Some("merged_with:attr-test-peer"));
        // Log an episode — it should inherit the tag.
        let id = crate::episode_db::episode_log(
            "test episode during merge",
            None,
            Some("existing-tag"),
            None,
            Some("win"),
            None,
            None,
        )
        .unwrap();
        assert!(id > 0);
        // Read it back and verify tag.
        let episodes = crate::episode_db::episode_recent(None, 5).unwrap();
        let found = episodes.iter().find(|e| e.id == id);
        assert!(found.is_some(), "episode should exist");
        let tags = found.unwrap().tags.as_deref().unwrap_or("");
        assert!(
            tags.contains("merged_with:attr-test-peer"),
            "expected merge attribution tag in episode tags, got: {}",
            tags
        );
        crate::fleet::end_merge();
    }

    #[test]
    #[serial]
    fn tools_ask_fleet_merge_bypasses_gate() {
        std::env::remove_var("CHUMP_FLEET_MERGE_APPROVE");
        std::env::set_var("CHUMP_TOOLS_ASK", "fleet_merge,other_tool");
        let result = check_merge_gate();
        std::env::remove_var("CHUMP_TOOLS_ASK");
        assert!(
            result.is_ok(),
            "CHUMP_TOOLS_ASK=fleet_merge should pass the gate"
        );
    }

    #[tokio::test]
    async fn exchange_workspace_requires_peer_id() {
        let tool = FleetTool::new();
        let out = tool
            .execute(json!({ "action": "exchange_workspace" }))
            .await
            .unwrap();
        assert!(out.contains("peer_id"), "got: {}", out);
    }

    #[tokio::test]
    async fn exchange_workspace_unregistered_peer_gives_clear_message() {
        let tool = FleetTool::new();
        let out = tool
            .execute(json!({
                "action": "exchange_workspace",
                "peer_id": "completely-unknown-peer-xyzzy-12345"
            }))
            .await
            .unwrap();
        assert!(
            out.contains("no peer") || out.contains("not registered"),
            "got: {}",
            out
        );
    }

    #[tokio::test]
    async fn exchange_workspace_peer_without_endpoint_gives_clear_message() {
        let id = unique("no-endpoint");
        crate::fleet::register_peer(FleetPeer {
            peer_id: id.clone(),
            role: "builder".to_string(),
            capabilities: vec![],
            endpoint: None, // no endpoint
            status: PeerStatus::Online,
            last_seen_unix: now_unix(),
            metadata_json: "{}".to_string(),
        })
        .unwrap();
        let tool = FleetTool::new();
        let out = tool
            .execute(json!({
                "action": "exchange_workspace",
                "peer_id": id
            }))
            .await
            .unwrap();
        crate::fleet::unregister_peer(&id).unwrap();
        assert!(
            out.contains("no endpoint") || out.contains("endpoint"),
            "got: {}",
            out
        );
    }

    #[tokio::test]
    async fn exchange_workspace_endpoint_override_unreachable_gives_graceful_error() {
        let tool = FleetTool::new();
        // Point at a port that should be refusing connections.
        let out = tool
            .execute(json!({
                "action": "exchange_workspace",
                "peer_id": "hypothetical-peer",
                "endpoint": "http://127.0.0.1:19999"
            }))
            .await
            .unwrap();
        // Should return an error string, not panic.
        assert!(
            out.contains("failed") || out.contains("error") || out.contains("Error"),
            "expected error message, got: {}",
            out
        );
    }

    #[tokio::test]
    #[serial]
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
        let out = tool
            .execute(json!({ "action": "heartbeat" }))
            .await
            .unwrap();
        assert!(out.contains("Heartbeat recorded"));
        crate::fleet::unregister_peer(&id).unwrap();
        std::env::remove_var("CHUMP_FLEET_PEER_ID");
    }
}
