//! PWA Tier 2 Phase 1.1: web session and message persistence (chump_web_sessions, chump_web_messages).
//! Uses shared db_pool (chump_memory.db).

use anyhow::Result;
use rusqlite::params;

use crate::db_pool;

const TITLE_PREVIEW_LEN: usize = 60;

/// Create a new session. Returns session id (uuid).
pub fn session_create(bot: &str) -> Result<String> {
    let id = uuid::Uuid::new_v4().to_string();
    let conn = db_pool::get()?;
    conn.execute(
        "INSERT INTO chump_web_sessions (id, bot) VALUES (?1, ?2)",
        params![id, bot],
    )?;
    Ok(id)
}

#[derive(serde::Serialize)]
pub struct WebSessionSummary {
    pub id: String,
    pub bot: String,
    pub title: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub message_count: u32,
    pub last_preview: Option<String>,
}

/// List sessions for a bot, newest first. limit/offset for pagination.
pub fn session_list(bot: &str, limit: u32, offset: u32) -> Result<Vec<WebSessionSummary>> {
    let conn = db_pool::get()?;
    let limit = limit.min(100);
    let mut stmt = conn.prepare(
        "
        SELECT s.id, s.bot, s.title, s.created_at, s.updated_at,
               (SELECT COUNT(*) FROM chump_web_messages m WHERE m.session_id = s.id) AS message_count,
               (SELECT content FROM chump_web_messages m WHERE m.session_id = s.id AND m.role = 'user' ORDER BY m.created_at DESC LIMIT 1) AS last_preview
        FROM chump_web_sessions s
        WHERE s.bot = ?1
        ORDER BY s.updated_at DESC
        LIMIT ?2 OFFSET ?3
        ",
    )?;
    let rows = stmt.query_map(params![bot, limit, offset], |r| {
        let last_preview: Option<String> = r.get(6)?;
        let preview = last_preview.map(|s| {
            let trim = s.trim();
            if trim.len() <= TITLE_PREVIEW_LEN {
                trim.to_string()
            } else {
                format!("{}…", trim.get(..TITLE_PREVIEW_LEN).unwrap_or(trim))
            }
        });
        Ok(WebSessionSummary {
            id: r.get(0)?,
            bot: r.get(1)?,
            title: r.get(2)?,
            created_at: r.get(3)?,
            updated_at: r.get(4)?,
            message_count: r.get::<_, i64>(5)? as u32,
            last_preview: preview,
        })
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

#[derive(serde::Serialize)]
pub struct WebMessage {
    pub id: i64,
    pub role: String,
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls_json: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attachments_json: Option<String>,
    pub created_at: String,
}

/// Get messages for a session, oldest first. limit/offset for pagination.
pub fn session_get_messages(session_id: &str, limit: u32, offset: u32) -> Result<Vec<WebMessage>> {
    let conn = db_pool::get()?;
    let limit = limit.min(500);
    let mut stmt = conn.prepare(
        "SELECT id, role, content, tool_calls_json, attachments_json, created_at
         FROM chump_web_messages WHERE session_id = ?1 ORDER BY created_at ASC LIMIT ?2 OFFSET ?3",
    )?;
    let rows = stmt.query_map(params![session_id, limit, offset], |r| {
        Ok(WebMessage {
            id: r.get(0)?,
            role: r.get(1)?,
            content: r.get(2)?,
            tool_calls_json: r.get(3)?,
            attachments_json: r.get(4)?,
            created_at: r.get(5)?,
        })
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

/// Delete a session and its messages.
pub fn session_delete(session_id: &str) -> Result<u64> {
    let conn = db_pool::get()?;
    conn.execute("DELETE FROM chump_web_messages WHERE session_id = ?1", params![session_id])?;
    let n = conn.execute("DELETE FROM chump_web_sessions WHERE id = ?1", params![session_id])?;
    Ok(n as u64)
}

/// Rename a session (set title).
pub fn session_rename(session_id: &str, title: &str) -> Result<u64> {
    let conn = db_pool::get()?;
    let n = conn.execute(
        "UPDATE chump_web_sessions SET title = ?1, updated_at = datetime('now') WHERE id = ?2",
        params![title.trim(), session_id],
    )?;
    Ok(n as u64)
}

fn session_touch(session_id: &str) -> Result<()> {
    let conn = db_pool::get()?;
    conn.execute("UPDATE chump_web_sessions SET updated_at = datetime('now') WHERE id = ?1", params![session_id])?;
    Ok(())
}

/// Append a user message. If this is the first message in the session, sets session title to first ~60 chars of content.
pub fn message_append_user(session_id: &str, content: &str, attachments_json: Option<&str>) -> Result<()> {
    let conn = db_pool::get()?;
    conn.execute(
        "INSERT INTO chump_web_messages (session_id, role, content, attachments_json) VALUES (?1, 'user', ?2, ?3)",
        params![session_id, content, attachments_json],
    )?;
    session_touch(session_id)?;
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM chump_web_messages WHERE session_id = ?1",
        params![session_id],
        |r| r.get(0),
    )?;
    if count == 1 {
        let title = content
            .trim()
            .chars()
            .take(TITLE_PREVIEW_LEN)
            .collect::<String>();
        if !title.is_empty() {
            let _ = conn.execute(
                "UPDATE chump_web_sessions SET title = ?1 WHERE id = ?2",
                params![title, session_id],
            );
        }
    }
    Ok(())
}

/// Append an assistant message (and optional tool_calls_json). Touches session updated_at.
pub fn message_append_assistant(session_id: &str, content: &str, tool_calls_json: Option<&str>) -> Result<()> {
    let conn = db_pool::get()?;
    conn.execute(
        "INSERT INTO chump_web_messages (session_id, role, content, tool_calls_json) VALUES (?1, 'assistant', ?2, ?3)",
        params![session_id, content, tool_calls_json],
    )?;
    session_touch(session_id)?;
    Ok(())
}

/// Resolve session id for chat: if empty or "default", create a new session; otherwise ensure a row exists for that id (INSERT OR IGNORE).
pub fn session_ensure(session_id: &str, bot: &str) -> Result<String> {
    let s = session_id.trim();
    if s.is_empty() || s.eq_ignore_ascii_case("default") {
        return session_create(bot);
    }
    let conn = db_pool::get()?;
    conn.execute(
        "INSERT OR IGNORE INTO chump_web_sessions (id, bot) VALUES (?1, ?2)",
        params![s, bot],
    )?;
    Ok(s.to_string())
}
