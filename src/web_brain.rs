//! PWA Tier 2: brain paths for ingest, research, watch, projects. Uses CHUMP_BRAIN_PATH like memory_brain_tool.

use anyhow::Result;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Max raw payload bytes for text capture (`/api/ingest` text, shortcut capture) before optional source prefix.
pub const MAX_INGEST_BYTES: usize = 512 * 1024;

fn brain_root() -> Result<PathBuf> {
    let root = std::env::var("CHUMP_BRAIN_PATH").unwrap_or_else(|_| "chump-brain".to_string());
    let base = crate::repo_path::runtime_base();
    Ok(if Path::new(&root).is_absolute() {
        PathBuf::from(root)
    } else {
        base.join(root)
    })
}

/// Unix days (since 1970-01-01) to (year, month, day) UTC. Approximate.
fn unix_days_to_ymd(days: i32) -> (i32, u32, u32) {
    let (y, m, d) = (
        days / 365,
        ((days % 365) / 31).min(11) as u32 + 1,
        ((days % 365) % 31).max(1) as u32,
    );
    (y + 1970, m, d)
}

fn safe_slug(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .take(80)
        .collect::<String>()
        .trim_matches('_')
        .to_string()
}

/// Write to capture/{date}-{slug}.{ext}. Returns (relative path, summary).
pub fn ingest_write(content: &[u8], ext: &str, summary_prefix: &str) -> Result<(String, String)> {
    let root = brain_root()?;
    let capture_dir = root.join("capture");
    std::fs::create_dir_all(&capture_dir)?;
    let date = {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let days = (t.as_secs() / 86400) as i32;
        let (y, m, d) = unix_days_to_ymd(days);
        format!("{:04}-{:02}-{:02}", y, m, d)
    };
    let slug = format!(
        "{:x}",
        (std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64)
            % 0xffff
    );
    let filename = format!(
        "{}-{}.{}",
        date,
        slug,
        if ext.is_empty() { "md" } else { ext }
    );
    let rel = format!("capture/{}", filename);
    let full = root.join(&rel);
    std::fs::write(&full, content)?;
    let summary = if content.len() > 200 {
        format!("{} ({} bytes)", summary_prefix, content.len())
    } else {
        let s = String::from_utf8_lossy(content);
        format!(
            "{}: {}",
            summary_prefix,
            s.trim().chars().take(100).collect::<String>()
        )
    };
    Ok((rel, summary))
}

/// Like [`ingest_write`], but rejects payloads over [`MAX_INGEST_BYTES`] and optionally prepends a
/// markdown/HTML comment so captures from Shortcuts vs PWA are distinguishable.
pub fn ingest_write_stamped(
    content: &[u8],
    ext: &str,
    summary_prefix: &str,
    source: Option<&str>,
) -> Result<(String, String)> {
    if content.len() > MAX_INGEST_BYTES {
        return Err(anyhow::anyhow!(
            "ingest payload exceeds {} bytes",
            MAX_INGEST_BYTES
        ));
    }
    let body: Vec<u8> = match source.map(str::trim).filter(|s| !s.is_empty()) {
        Some(s) => {
            let safe = s.replace("-->", "");
            let header = format!("<!-- capture_source: {} -->\n\n", safe);
            let mut v = header.into_bytes();
            v.extend_from_slice(content);
            v
        }
        None => content.to_vec(),
    };
    ingest_write(&body, ext, summary_prefix)
}

/// List research briefs: research/*.md. Returns vec of (id, topic, path).
pub fn research_list() -> Result<Vec<(String, String, String)>> {
    let root = brain_root()?;
    let dir = root.join("research");
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for e in std::fs::read_dir(&dir)? {
        let e = e?;
        let name = e.file_name().to_string_lossy().to_string();
        if name.ends_with(".md") {
            let id = name.trim_end_matches(".md").to_string();
            let topic = id.replace('_', " ");
            out.push((id.clone(), topic, format!("research/{}", name)));
        }
    }
    out.sort_by(|a, b| b.2.cmp(&a.2));
    Ok(out)
}

/// Write research brief (create or overwrite). Returns path.
pub fn research_create(topic: &str, content: &str) -> Result<String> {
    let root = brain_root()?;
    let dir = root.join("research");
    std::fs::create_dir_all(&dir)?;
    let slug = safe_slug(topic);
    let id = if slug.is_empty() {
        "brief".to_string()
    } else {
        slug
    };
    let rel = format!("research/{}.md", id);
    let full = root.join(&rel);
    let body = format!("# Research: {}\n\nStatus: queued\n\n{}", topic, content);
    std::fs::write(&full, body)?;
    Ok(rel)
}

/// Read research brief by id (filename without .md).
pub fn research_get(id: &str) -> Result<String> {
    let root = brain_root()?;
    let safe = safe_slug(id);
    let rel = format!(
        "research/{}.md",
        if safe.is_empty() { "brief" } else { &safe }
    );
    let full = root.join(&rel);
    std::fs::read_to_string(&full).map_err(Into::into)
}

/// List watchlists: watch/*.md. Returns list names and item count.
pub fn watch_list() -> Result<Vec<(String, usize)>> {
    let root = brain_root()?;
    let dir = root.join("watch");
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for e in std::fs::read_dir(&dir)? {
        let e = e?;
        let name = e.file_name().to_string_lossy().to_string();
        if name.ends_with(".md") {
            let list_name = name.trim_end_matches(".md").to_string();
            let content = std::fs::read_to_string(e.path()).unwrap_or_default();
            let lines = content
                .lines()
                .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
                .count();
            out.push((list_name, lines));
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

/// Append item to a watchlist file.
pub fn watch_add(list: &str, item_line: &str) -> Result<()> {
    let root = brain_root()?;
    let safe_list = safe_slug(list);
    let rel = format!(
        "watch/{}.md",
        if safe_list.is_empty() {
            "misc"
        } else {
            &safe_list
        }
    );
    let full = root.join(rel);
    if let Some(dir) = full.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let line = format!("- {}  \n", item_line.trim());
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&full)?
        .write_all(line.as_bytes())?;
    Ok(())
}

/// One watchlist line flagged as needing attention (heuristic for PWA / briefing).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatchFlaggedItem {
    pub list: String,
    pub line: String,
}

fn watch_line_is_flagged(line: &str) -> bool {
    let t = line.trim();
    if !t.starts_with('-') {
        return false;
    }
    let lower = t.to_lowercase();
    lower.contains("[!]")
        || lower.contains("!!!")
        || lower.contains("urgent")
        || lower.contains("asap")
        || lower.contains("deadline")
        || lower.contains("alert:")
}

/// Scan `watch/*.md` for bullet lines that look actionable (urgent / deadline / explicit alert markers).
pub fn watch_flagged_items() -> Result<Vec<WatchFlaggedItem>> {
    let root = brain_root()?;
    let dir = root.join("watch");
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for e in std::fs::read_dir(&dir)? {
        let e = e?;
        let name = e.file_name().to_string_lossy().to_string();
        if !name.ends_with(".md") {
            continue;
        }
        let list_name = name.trim_end_matches(".md").to_string();
        let content = std::fs::read_to_string(e.path()).unwrap_or_default();
        for line in content.lines() {
            if watch_line_is_flagged(line) {
                out.push(WatchFlaggedItem {
                    list: list_name.clone(),
                    line: line.trim().to_string(),
                });
            }
        }
    }
    out.sort_by(|a, b| a.list.cmp(&b.list).then_with(|| a.line.cmp(&b.line)));
    Ok(out)
}

/// Remove one item from a watchlist by 0-based line index (non-header, non-empty lines only).
pub fn watch_remove(list: &str, item_index: usize) -> Result<()> {
    let root = brain_root()?;
    let safe_list = safe_slug(list);
    let rel = format!(
        "watch/{}.md",
        if safe_list.is_empty() {
            "misc"
        } else {
            &safe_list
        }
    );
    let full = root.join(&rel);
    let content = std::fs::read_to_string(&full).unwrap_or_default();
    let lines: Vec<&str> = content.lines().collect();
    let item_lines: Vec<&str> = lines
        .iter()
        .filter(|l| !l.trim().is_empty() && !l.trim().starts_with('#'))
        .copied()
        .collect();
    if item_index >= item_lines.len() {
        return Err(anyhow::anyhow!("item index out of range"));
    }
    let to_remove = item_lines[item_index];
    let new_content: String = lines
        .into_iter()
        .filter(|l| l != &to_remove)
        .collect::<Vec<_>>()
        .join("\n");
    std::fs::write(&full, new_content)?;
    Ok(())
}

/// List projects: projects/*.md or single projects.md. Returns vec of (id, name, path).
pub fn projects_list() -> Result<Vec<(String, String, String)>> {
    let root = brain_root()?;
    let dir = root.join("projects");
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for e in std::fs::read_dir(&dir)? {
        let e = e?;
        let name = e.file_name().to_string_lossy().to_string();
        if name.ends_with(".md") {
            let id = name.trim_end_matches(".md").to_string();
            let content = std::fs::read_to_string(e.path()).unwrap_or_default();
            let first_line = content
                .lines()
                .next()
                .unwrap_or("")
                .trim_start_matches('#')
                .trim();
            out.push((
                id.clone(),
                first_line.to_string(),
                format!("projects/{}", name),
            ));
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

/// Add project: write projects/{name}.md.
pub fn project_add(name: &str, repo_path: &str, description: &str) -> Result<String> {
    let root = brain_root()?;
    let dir = root.join("projects");
    std::fs::create_dir_all(&dir)?;
    let slug = safe_slug(name);
    let id = if slug.is_empty() { "project" } else { &slug };
    let rel = format!("projects/{}.md", id);
    let full = root.join(&rel);
    let body = format!("# {}\n\nrepo: {}\n\n{}\n", name, repo_path, description);
    std::fs::write(&full, body)?;
    Ok(rel)
}

/// Set active project (write id to chump-brain/active_project.txt for context).
pub fn project_activate(project_id: &str) -> Result<()> {
    let root = brain_root()?;
    let path = root.join("active_project.txt");
    std::fs::write(path, project_id.trim())?;
    Ok(())
}

/// Latest files under `cos/decisions/*.md` (newest mtime first) for PWA read-only surfacing.
#[derive(serde::Serialize)]
pub struct CosDecisionSummary {
    pub filename: String,
    pub relative_path: String,
    pub modified_unix_ms: i64,
    pub preview: String,
}

pub fn cos_decisions_recent(limit: usize) -> Result<Vec<CosDecisionSummary>> {
    let root = brain_root()?;
    let dir = root.join("cos").join("decisions");
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let limit = limit.clamp(1, 50);
    let mut entries: Vec<(i64, String, String)> = Vec::new();
    for e in std::fs::read_dir(&dir)? {
        let e = e?;
        let path = e.path();
        if path.extension().and_then(|s| s.to_str()) != Some("md") {
            continue;
        }
        let meta = std::fs::metadata(&path).ok();
        let mtime = meta
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let filename = e.file_name().to_string_lossy().to_string();
        let content = std::fs::read_to_string(&path).unwrap_or_default();
        let preview: String = content.chars().take(480).collect();
        entries.push((mtime, filename, preview));
    }
    entries.sort_by(|a, b| b.0.cmp(&a.0));
    Ok(entries
        .into_iter()
        .take(limit)
        .map(|(modified_unix_ms, filename, preview)| CosDecisionSummary {
            relative_path: format!("cos/decisions/{}", filename),
            filename: filename.clone(),
            modified_unix_ms,
            preview,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ingest_write_stamped_rejects_oversize() {
        let big = vec![b'x'; MAX_INGEST_BYTES + 1];
        let err = ingest_write_stamped(&big, "md", "Note", None).unwrap_err();
        assert!(err.to_string().contains("exceeds"));
    }

    #[test]
    fn watch_line_is_flagged_heuristic() {
        assert!(super::watch_line_is_flagged("- deal closing [URGENT]"));
        assert!(super::watch_line_is_flagged("- fix this [!]"));
        assert!(super::watch_line_is_flagged("- pay rent deadline: friday"));
        assert!(!super::watch_line_is_flagged("- normal todo"));
        assert!(!super::watch_line_is_flagged("not a bullet"));
    }
}
