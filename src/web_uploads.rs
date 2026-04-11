//! PWA Tier 2 Phase 1.2: file upload storage. Files under sessions/uploads/{session_id}/{file_id}-{filename}.

use anyhow::Result;
use rusqlite::params;
use std::path::Path;

use crate::db_pool;
use crate::repo_path;

const MAX_FILE_BYTES: usize = 10 * 1024 * 1024; // 10MB

fn sanitize_filename(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect::<String>()
        .trim_matches('.')
        .to_string()
}

fn uploads_base() -> std::path::PathBuf {
    repo_path::runtime_base().join("sessions").join("uploads")
}

/// Save uploaded bytes; returns (file_id, size_bytes). Enforces 10MB max.
pub fn save_upload(
    session_id: &str,
    filename: &str,
    mime_type: Option<&str>,
    data: &[u8],
) -> Result<(String, u64)> {
    if data.len() > MAX_FILE_BYTES {
        anyhow::bail!("file too large (max {} bytes)", MAX_FILE_BYTES);
    }
    let file_id = uuid::Uuid::new_v4().to_string();
    let safe_name = if filename.is_empty() {
        "file".to_string()
    } else {
        sanitize_filename(filename)
    };
    let storage_path = format!("{}/{}-{}", session_id, file_id, safe_name);
    let full_path = uploads_base().join(&storage_path);
    std::fs::create_dir_all(full_path.parent().unwrap())?;
    std::fs::write(&full_path, data)?;
    let size_bytes = data.len() as u64;
    let conn = db_pool::get()?;
    conn.execute(
        "INSERT INTO chump_web_uploads (file_id, session_id, filename, mime_type, size_bytes, storage_path) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![file_id, session_id, filename, mime_type, size_bytes as i64, storage_path],
    )?;
    Ok((file_id, size_bytes))
}

/// Lookup upload by file_id. Returns (full path, filename, mime_type) for serving.
pub fn get_upload(file_id: &str) -> Result<(std::path::PathBuf, String, Option<String>)> {
    let conn = db_pool::get()?;
    let (storage_path, filename, mime_type): (String, String, Option<String>) = conn.query_row(
        "SELECT storage_path, filename, mime_type FROM chump_web_uploads WHERE file_id = ?1",
        params![file_id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    let full_path = uploads_base().join(Path::new(&storage_path));
    if !full_path.exists() {
        anyhow::bail!("upload file missing on disk");
    }
    Ok((full_path, filename, mime_type))
}

/// Read file contents as text if it looks like text; otherwise None (for images/binary).
pub fn read_upload_as_text(file_id: &str) -> Result<Option<String>> {
    let (path, _, mime_type) = get_upload(file_id)?;
    let data = std::fs::read(&path)?;
    let mime = mime_type.as_deref().unwrap_or("");
    let is_text = mime.starts_with("text/")
        || mime == "application/json"
        || mime == "application/yaml"
        || mime.contains("xml")
        || data.iter().all(|&b| b.is_ascii() || b >= 128);
    if is_text {
        Ok(Some(String::from_utf8_lossy(&data).to_string()))
    } else {
        Ok(None)
    }
}

/// Delete all uploads for a session (files + DB rows). Call when session is deleted.
pub fn delete_uploads_for_session(session_id: &str) -> Result<()> {
    let conn = db_pool::get()?;
    let mut stmt =
        conn.prepare("SELECT file_id, storage_path FROM chump_web_uploads WHERE session_id = ?1")?;
    let rows = stmt.query_map(params![session_id], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })?;
    let base = uploads_base();
    for row in rows {
        let (_, storage_path): (String, String) = row?;
        let full = base.join(Path::new(&storage_path));
        let _ = std::fs::remove_file(&full);
    }
    conn.execute(
        "DELETE FROM chump_web_uploads WHERE session_id = ?1",
        params![session_id],
    )?;
    Ok(())
}
