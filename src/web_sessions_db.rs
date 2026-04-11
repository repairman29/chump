//! PWA Tier 2 Phase 1.1: web session and message persistence (chump_web_sessions, chump_web_messages).
//! Uses shared db_pool (chump_memory.db).
//! FTS5 (`web_messages_fts`) backs verbatim retrieval for long-context trimming (Vector 2).

use anyhow::Result;
use rusqlite::params;
use std::fmt::Write;

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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_monologue: Option<String>,
    pub created_at: String,
}

/// Get messages for a session, oldest first. limit/offset for pagination.
pub fn session_get_messages(session_id: &str, limit: u32, offset: u32) -> Result<Vec<WebMessage>> {
    let conn = db_pool::get()?;
    let limit = limit.min(500);
    let mut stmt = conn.prepare(
        "SELECT id, role, content, tool_calls_json, attachments_json, thinking_monologue, created_at
         FROM chump_web_messages WHERE session_id = ?1 ORDER BY created_at ASC LIMIT ?2 OFFSET ?3",
    )?;
    let rows = stmt.query_map(params![session_id, limit, offset], |r| {
        Ok(WebMessage {
            id: r.get(0)?,
            role: r.get(1)?,
            content: r.get(2)?,
            tool_calls_json: r.get(3)?,
            attachments_json: r.get(4)?,
            thinking_monologue: r.get(5)?,
            created_at: r.get(6)?,
        })
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

/// Delete a session and its messages.
pub fn session_delete(session_id: &str) -> Result<u64> {
    let conn = db_pool::get()?;
    conn.execute(
        "DELETE FROM chump_web_messages WHERE session_id = ?1",
        params![session_id],
    )?;
    let n = conn.execute(
        "DELETE FROM chump_web_sessions WHERE id = ?1",
        params![session_id],
    )?;
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
    conn.execute(
        "UPDATE chump_web_sessions SET updated_at = datetime('now') WHERE id = ?1",
        params![session_id],
    )?;
    Ok(())
}

/// Append a user message. If this is the first message in the session, sets session title to first ~60 chars of content.
pub fn message_append_user(
    session_id: &str,
    content: &str,
    attachments_json: Option<&str>,
) -> Result<()> {
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

/// Append an assistant message (optional `tool_calls_json`, optional `thinking_monologue` from `<thinking>` blocks).
/// Touches session `updated_at`.
pub fn message_append_assistant(
    session_id: &str,
    content: &str,
    tool_calls_json: Option<&str>,
    thinking_monologue: Option<&str>,
) -> Result<()> {
    let conn = db_pool::get()?;
    conn.execute(
        "INSERT INTO chump_web_messages (session_id, role, content, tool_calls_json, thinking_monologue) VALUES (?1, 'assistant', ?2, ?3, ?4)",
        params![
            session_id,
            content,
            tool_calls_json,
            thinking_monologue
        ],
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

/// Escape tokens for FTS5 `MATCH` (same strategy as `memory_db`).
fn escape_fts5_query(s: &str) -> String {
    let tokens: Vec<String> = s
        .split_whitespace()
        .take(16)
        .map(|t| {
            let escaped = t.replace('"', "\"\"");
            format!("\"{}\"", escaped)
        })
        .collect();
    tokens.join(" OR ")
}

/// Verbatim excerpts from this session: BM25-ranked when `query` has tokens, else latest messages.
pub fn session_messages_fts_snippets(session_id: &str, query: &str, limit: usize) -> Result<String> {
    let conn = db_pool::get()?;
    let fts_ok: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='web_messages_fts'",
        [],
        |r| r.get(0),
    )?;
    if fts_ok == 0 {
        return Ok(String::new());
    }
    let limit = limit.min(24).max(1);
    let pattern = escape_fts5_query(query);
    let mut out = String::new();
    if pattern.is_empty() {
        let mut stmt = conn.prepare(
            "SELECT role, content FROM chump_web_messages WHERE session_id = ?1 ORDER BY id DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![session_id, limit], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?;
        for r in rows {
            let (role, content) = r?;
            let _ = writeln!(out, "---\n[{}] {}\n---\n", role, content);
        }
        return Ok(out);
    }
    let sql = "SELECT m.role, m.content
         FROM web_messages_fts f
         INNER JOIN chump_web_messages m ON m.id = f.rowid
         WHERE m.session_id = ?1 AND f MATCH ?2
         ORDER BY m.id DESC
         LIMIT ?3";
    let mut stmt = conn.prepare(sql)?;
    let rows = match stmt.query_map(params![session_id, &pattern, limit], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    }) {
        Ok(r) => r,
        Err(_) => return Ok(String::new()),
    };
    for r in rows {
        let Ok((role, content)) = r else { continue };
        let _ = writeln!(out, "---\n[{}] {}\n---\n", role, content);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[serial_test::serial]
    fn assistant_message_roundtrips_thinking_monologue() {
        let sid = session_create("chump").expect("session_create");
        message_append_user(&sid, "hello", None).expect("user msg");
        message_append_assistant(
            &sid,
            "visible reply",
            None,
            Some("step one\n---\nstep two"),
        )
        .expect("assistant msg");
        let msgs = session_get_messages(&sid, 50, 0).expect("get messages");
        let assistant = msgs.iter().find(|m| m.role == "assistant").expect("assistant row");
        assert_eq!(assistant.content, "visible reply");
        assert_eq!(
            assistant.thinking_monologue.as_deref(),
            Some("step one\n---\nstep two")
        );
        let _ = session_delete(&sid);
    }
}
