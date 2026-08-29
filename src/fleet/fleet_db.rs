//! Fleet coordination database layer — persistence for [`crate::fleet`].
//!
//! Schema is provisioned in [`crate::db_pool::init_schema`]. This module wraps the
//! raw SQL with typed helpers used by `fleet.rs` and `fleet_tool.rs`. All writes
//! use `INSERT OR REPLACE` to handle concurrent peer updates gracefully.

use crate::fleet::{FleetPeer, PeerStatus};
use anyhow::Result;
use rusqlite::params;

/// Insert or replace a peer record (idempotent).
pub fn upsert_peer(peer: &FleetPeer) -> Result<()> {
    let conn = crate::db_pool::get()?;
    let caps_json = serde_json::to_string(&peer.capabilities).unwrap_or_else(|_| "[]".to_string());
    conn.execute(
        "INSERT OR REPLACE INTO chump_fleet_peers \
            (peer_id, role, capabilities_json, endpoint, status, last_seen_unix, metadata_json, registered_at, updated_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, \
            COALESCE((SELECT registered_at FROM chump_fleet_peers WHERE peer_id = ?1), datetime('now')), \
            datetime('now'))",
        params![
            peer.peer_id,
            peer.role,
            caps_json,
            peer.endpoint,
            peer.status.as_str(),
            peer.last_seen_unix as i64,
            peer.metadata_json,
        ],
    )?;
    Ok(())
}

/// Delete a peer by id. No-op if it doesn't exist.
pub fn delete_peer(peer_id: &str) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "DELETE FROM chump_fleet_peers WHERE peer_id = ?1",
        params![peer_id],
    )?;
    Ok(())
}

/// Update only the status (and updated_at, last_seen_unix).
pub fn update_status(peer_id: &str, status: PeerStatus, now_unix: u64) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "UPDATE chump_fleet_peers \
         SET status = ?1, last_seen_unix = ?2, updated_at = datetime('now') \
         WHERE peer_id = ?3",
        params![status.as_str(), now_unix as i64, peer_id],
    )?;
    Ok(())
}

/// Bump last_seen_unix and updated_at (heartbeat).
pub fn touch_last_seen(peer_id: &str, now_unix: u64) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "UPDATE chump_fleet_peers \
         SET last_seen_unix = ?1, updated_at = datetime('now') \
         WHERE peer_id = ?2",
        params![now_unix as i64, peer_id],
    )?;
    Ok(())
}

/// Return all peers ordered by peer_id.
pub fn list_all_peers() -> Result<Vec<FleetPeer>> {
    let conn = crate::db_pool::get()?;
    let mut stmt = conn.prepare(
        "SELECT peer_id, role, capabilities_json, endpoint, status, last_seen_unix, metadata_json \
         FROM chump_fleet_peers ORDER BY peer_id",
    )?;
    let rows = stmt.query_map([], row_to_peer)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

/// Fetch a single peer by id.
pub fn get_peer(peer_id: &str) -> Result<Option<FleetPeer>> {
    let conn = crate::db_pool::get()?;
    let mut stmt = conn.prepare(
        "SELECT peer_id, role, capabilities_json, endpoint, status, last_seen_unix, metadata_json \
         FROM chump_fleet_peers WHERE peer_id = ?1",
    )?;
    let mut rows = stmt.query(params![peer_id])?;
    if let Some(r) = rows.next()? {
        Ok(Some(row_to_peer(r)?))
    } else {
        Ok(None)
    }
}

fn row_to_peer(r: &rusqlite::Row) -> rusqlite::Result<FleetPeer> {
    let caps_json: String = r.get(2)?;
    let capabilities: Vec<String> = serde_json::from_str(&caps_json).unwrap_or_default();
    let status_str: String = r.get(4)?;
    let last_seen: i64 = r.get(5)?;
    Ok(FleetPeer {
        peer_id: r.get(0)?,
        role: r.get(1)?,
        capabilities,
        endpoint: r.get(3)?,
        status: PeerStatus::from_str(&status_str),
        last_seen_unix: last_seen.max(0) as u64,
        metadata_json: r.get(6)?,
    })
}

/// Insert a dispatch row (V1 records intent, doesn't execute remotely). Returns rowid.
pub fn record_dispatch(
    from_peer: &str,
    to_peer: Option<&str>,
    task_description: &str,
    priority: u32,
) -> Result<i64> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "INSERT INTO chump_fleet_dispatches (from_peer, to_peer, task_description, priority, status) \
         VALUES (?1, ?2, ?3, ?4, 'pending')",
        params![from_peer, to_peer, task_description, priority as i64],
    )?;
    Ok(conn.last_insert_rowid())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fleet::PeerStatus;

    fn unique(tag: &str) -> String {
        format!(
            "test-fleet-{}-{}-{}",
            tag,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        )
    }

    fn make_peer(id: &str, role: &str, caps: &[&str]) -> FleetPeer {
        FleetPeer {
            peer_id: id.to_string(),
            role: role.to_string(),
            capabilities: caps.iter().map(|s| s.to_string()).collect(),
            endpoint: None,
            status: PeerStatus::Online,
            last_seen_unix: 1_700_000_000,
            metadata_json: "{}".to_string(),
        }
    }

    #[test]
    fn upsert_and_get_roundtrip() {
        let id = unique("upsert");
        let peer = make_peer(&id, "builder", &["rust", "git"]);
        upsert_peer(&peer).unwrap();
        let got = get_peer(&id).unwrap().expect("present");
        assert_eq!(got.peer_id, id);
        assert_eq!(got.role, "builder");
        assert_eq!(got.capabilities, vec!["rust", "git"]);
        assert_eq!(got.status, PeerStatus::Online);
    }

    #[test]
    fn upsert_replaces_existing() {
        let id = unique("replace");
        upsert_peer(&make_peer(&id, "builder", &["rust"])).unwrap();
        let mut updated = make_peer(&id, "sentinel", &["python"]);
        updated.status = PeerStatus::Busy;
        upsert_peer(&updated).unwrap();
        let got = get_peer(&id).unwrap().expect("present");
        assert_eq!(got.role, "sentinel");
        assert_eq!(got.capabilities, vec!["python"]);
        assert_eq!(got.status, PeerStatus::Busy);
    }

    #[test]
    fn delete_peer_works() {
        let id = unique("delete");
        upsert_peer(&make_peer(&id, "builder", &[])).unwrap();
        assert!(get_peer(&id).unwrap().is_some());
        delete_peer(&id).unwrap();
        assert!(get_peer(&id).unwrap().is_none());
    }

    #[test]
    fn update_status_changes_only_status_and_seen() {
        let id = unique("status");
        upsert_peer(&make_peer(&id, "builder", &["rust"])).unwrap();
        update_status(&id, PeerStatus::Offline, 1_800_000_000).unwrap();
        let got = get_peer(&id).unwrap().unwrap();
        assert_eq!(got.status, PeerStatus::Offline);
        assert_eq!(got.last_seen_unix, 1_800_000_000);
        assert_eq!(got.role, "builder"); // unchanged
    }

    #[test]
    fn list_all_peers_returns_inserted() {
        let id = unique("list");
        upsert_peer(&make_peer(&id, "builder", &[])).unwrap();
        let all = list_all_peers().unwrap();
        assert!(all.iter().any(|p| p.peer_id == id));
    }

    #[test]
    fn record_dispatch_returns_rowid() {
        let id = unique("dispatch");
        let rid = record_dispatch(&id, Some("other-peer"), "do thing", 1).unwrap();
        assert!(rid > 0);
    }
}
