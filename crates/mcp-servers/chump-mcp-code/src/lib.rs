//! INFRA-8076 (INFRA-1583 slice): tree-sitter code indexer behind `chump-mcp-code`.
//!
//! Indexes top-level symbols of Rust, bash and Python files into a SQLite
//! database (`.chump/code_index.db`, separate from `state.db`). Parsing is done by
//! the shared `chump-ast-crawler` tree-sitter extractor; this crate owns storage,
//! incremental updates and queries.
//!
//! Incremental by construction: every file row carries a content hash, so
//! re-indexing skips unchanged files; a path that no longer exists (deleted or
//! renamed in a commit) is removed from the index.

use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Command;

pub mod phase1;

/// Languages this index covers (the AC set).
pub const INDEXED_LANGUAGES: [&str; 3] = ["rust", "bash", "python"];

/// Default index location: `<repo>/.chump/code_index.db`, overridable with
/// `CHUMP_CODE_INDEX_DB`.
pub fn db_path(repo_root: &Path) -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_CODE_INDEX_DB") {
        if !p.trim().is_empty() {
            return PathBuf::from(p);
        }
    }
    repo_root.join(".chump").join("code_index.db")
}

/// Open (creating if needed) the index database and apply the schema.
pub fn open_db(path: &Path) -> Result<Connection> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    let conn = Connection::open(path).with_context(|| format!("opening {}", path.display()))?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS files (
             path TEXT PRIMARY KEY,
             language TEXT NOT NULL,
             content_hash TEXT NOT NULL,
             indexed_at INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS symbols (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
             name TEXT NOT NULL,
             kind TEXT NOT NULL,
             line INTEGER NOT NULL,
             doc_first_line TEXT
         );
         CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
         CREATE INDEX IF NOT EXISTS idx_symbols_path ON symbols(path);",
    )
    .context("applying code index schema")?;
    Ok(conn)
}

/// FNV-1a 64-bit over the file bytes — stable across runs and platforms.
fn content_hash(bytes: &[u8]) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// What an indexing pass did.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize)]
pub struct IndexStats {
    /// Files (re)parsed and written.
    pub indexed: usize,
    /// Files skipped because their content hash is unchanged.
    pub unchanged: usize,
    /// Files of a language this index does not cover.
    pub unsupported: usize,
    /// Index rows removed because the file no longer exists / is no longer indexable.
    pub removed: usize,
    /// Symbols written by this pass.
    pub symbols: usize,
}

fn remove_path(conn: &Connection, rel: &str) -> Result<bool> {
    conn.execute("DELETE FROM symbols WHERE path = ?1", params![rel])?;
    Ok(conn.execute("DELETE FROM files WHERE path = ?1", params![rel])? > 0)
}

/// Index the given repo-relative paths. A path that does not exist on disk (a
/// deleted/renamed file) is removed from the index.
pub fn index_files(
    conn: &Connection,
    repo_root: &Path,
    rel_paths: &[String],
) -> Result<IndexStats> {
    let mut stats = IndexStats::default();
    for rel in rel_paths {
        let abs = repo_root.join(rel);
        let bytes = match std::fs::read(&abs) {
            Ok(b) => b,
            Err(_) => {
                if remove_path(conn, rel)? {
                    stats.removed += 1;
                }
                continue;
            }
        };
        let shape = match chump_ast_crawler::crawl_file(&abs) {
            Ok(s) => s,
            Err(_) => {
                stats.unsupported += 1;
                continue;
            }
        };
        if !shape.supported || !INDEXED_LANGUAGES.contains(&shape.language.as_str()) {
            // A file that stopped being indexable (e.g. renamed to .txt) must not linger.
            if remove_path(conn, rel)? {
                stats.removed += 1;
            }
            stats.unsupported += 1;
            continue;
        }
        let hash = content_hash(&bytes);
        let prev: Option<String> = conn
            .query_row(
                "SELECT content_hash FROM files WHERE path = ?1",
                params![rel],
                |r| r.get(0),
            )
            .ok();
        if prev.as_deref() == Some(hash.as_str()) {
            stats.unchanged += 1;
            continue;
        }
        let tx = conn.unchecked_transaction()?;
        tx.execute("DELETE FROM symbols WHERE path = ?1", params![rel])?;
        tx.execute(
            "INSERT INTO files (path, language, content_hash, indexed_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(path) DO UPDATE SET language = ?2, content_hash = ?3, indexed_at = ?4",
            params![rel, shape.language, hash, now_secs()],
        )?;
        for s in &shape.top_level_symbols {
            tx.execute(
                "INSERT INTO symbols (path, name, kind, line, doc_first_line) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![rel, s.name, s.kind, s.line as i64, s.doc_first_line],
            )?;
            stats.symbols += 1;
        }
        tx.commit()?;
        stats.indexed += 1;
    }
    Ok(stats)
}

fn is_skip_dir(name: &str) -> bool {
    (name.starts_with('.') && name != ".")
        || matches!(
            name,
            "target" | "node_modules" | "vendor" | "dist" | "build" | "__pycache__"
        )
}

fn walk(dir: &Path, root: &Path, out: &mut Vec<String>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<_> = rd.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        let p = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        if p.is_dir() {
            if !is_skip_dir(&name) {
                walk(&p, root, out);
            }
        } else if matches!(
            p.extension().and_then(|x| x.to_str()),
            Some("rs" | "sh" | "bash" | "py")
        ) {
            if let Ok(rel) = p.strip_prefix(root) {
                out.push(rel.to_string_lossy().into_owned());
            }
        }
    }
}

/// Every candidate source path in the repo: tracked files from `git ls-files`
/// when available, else a directory walk.
pub fn repo_source_paths(repo_root: &Path) -> Vec<String> {
    let git = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["ls-files", "-z"])
        .output()
        .ok()
        .filter(|o| o.status.success());
    let mut out: Vec<String> = match git {
        Some(o) => String::from_utf8_lossy(&o.stdout)
            .split('\0')
            .filter(|p| {
                matches!(
                    Path::new(p).extension().and_then(|x| x.to_str()),
                    Some("rs" | "sh" | "bash" | "py")
                )
            })
            .map(String::from)
            .collect(),
        None => {
            let mut v = Vec::new();
            walk(repo_root, repo_root, &mut v);
            v
        }
    };
    out.sort();
    out
}

/// Index the whole repo and drop rows for files that no longer exist.
pub fn index_repo(conn: &Connection, repo_root: &Path) -> Result<IndexStats> {
    let paths = repo_source_paths(repo_root);
    let mut stats = index_files(conn, repo_root, &paths)?;
    let known: Vec<String> = {
        let mut stmt = conn.prepare("SELECT path FROM files")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        rows.filter_map(|r| r.ok()).collect()
    };
    let gone: Vec<String> = known.into_iter().filter(|p| !paths.contains(p)).collect();
    stats.removed += index_files(conn, repo_root, &gone)?.removed;
    Ok(stats)
}

/// Paths touched by `HEAD` (added/modified/deleted/renamed) — what the post-commit
/// hook re-indexes.
pub fn changed_files_in_head(repo_root: &Path) -> Vec<String> {
    Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args([
            "diff-tree",
            "--no-commit-id",
            "--name-only",
            "-r",
            "--root",
            "-z",
            "HEAD",
        ])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .split('\0')
                .filter(|p| !p.is_empty())
                .map(String::from)
                .collect()
        })
        .unwrap_or_default()
}

/// One indexed symbol.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SymbolRow {
    pub path: String,
    pub name: String,
    pub kind: String,
    pub line: i64,
    pub language: String,
    pub doc_first_line: Option<String>,
}

fn map_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<SymbolRow> {
    Ok(SymbolRow {
        path: r.get(0)?,
        name: r.get(1)?,
        kind: r.get(2)?,
        line: r.get(3)?,
        language: r.get(4)?,
        doc_first_line: r.get(5)?,
    })
}

const SYMBOL_SELECT: &str = "SELECT s.path, s.name, s.kind, s.line, f.language, s.doc_first_line
     FROM symbols s JOIN files f ON f.path = s.path";

/// Case-insensitive substring match on symbol name; exact matches first.
pub fn search_symbols(
    conn: &Connection,
    query: &str,
    kind: Option<&str>,
    limit: usize,
) -> Result<Vec<SymbolRow>> {
    let like = format!(
        "%{}%",
        query
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_")
    );
    let sql = format!(
        "{SYMBOL_SELECT} WHERE s.name LIKE ?1 ESCAPE '\\' AND (?2 IS NULL OR s.kind = ?2)
         ORDER BY (lower(s.name) = lower(?3)) DESC, length(s.name), s.path, s.line LIMIT ?4"
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params![like, kind, query, limit as i64], map_row)?;
    Ok(rows.filter_map(|r| r.ok()).collect())
}

/// Symbols indexed for one repo-relative file, in line order.
pub fn file_symbols(conn: &Connection, path: &str) -> Result<Vec<SymbolRow>> {
    let sql = format!("{SYMBOL_SELECT} WHERE s.path = ?1 ORDER BY s.line");
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params![path], map_row)?;
    Ok(rows.filter_map(|r| r.ok()).collect())
}

/// Totals plus a per-language breakdown.
pub fn index_summary(conn: &Connection) -> Result<serde_json::Value> {
    let files: i64 = conn.query_row("SELECT COUNT(*) FROM files", [], |r| r.get(0))?;
    let symbols: i64 = conn.query_row("SELECT COUNT(*) FROM symbols", [], |r| r.get(0))?;
    let mut by_language = serde_json::Map::new();
    let mut stmt = conn.prepare(
        "SELECT f.language, COUNT(DISTINCT f.path), COUNT(s.id)
         FROM files f LEFT JOIN symbols s ON s.path = f.path GROUP BY f.language ORDER BY f.language",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, i64>(2)?,
        ))
    })?;
    for (lang, f, s) in rows.flatten() {
        by_language.insert(lang, serde_json::json!({"files": f, "symbols": s}));
    }
    Ok(serde_json::json!({"files": files, "symbols": symbols, "by_language": by_language}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn fixture() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(
            root.join("src/lib.rs"),
            "/// Adds two numbers.\npub fn add(a: i32, b: i32) -> i32 { a + b }\npub struct Widget;\n",
        )
        .unwrap();
        fs::write(
            root.join("tool.sh"),
            "#!/usr/bin/env bash\nsay_hello() { echo hi; }\n",
        )
        .unwrap();
        fs::write(
            root.join("mod.py"),
            "def compute():\n    return 1\n\nclass Thing:\n    pass\n",
        )
        .unwrap();
        fs::write(root.join("notes.txt"), "not code").unwrap();
        let conn = open_db(&root.join(".chump/code_index.db")).unwrap();
        (dir, conn)
    }

    #[test]
    fn indexes_rust_bash_and_python_symbols() {
        let (dir, conn) = fixture();
        let stats = index_repo(&conn, dir.path()).unwrap();
        assert_eq!(stats.indexed, 3, "{stats:?}");
        let langs = index_summary(&conn).unwrap();
        for l in ["rust", "bash", "python"] {
            assert!(
                langs["by_language"][l]["symbols"].as_i64().unwrap() >= 1,
                "no {l} symbols: {langs}"
            );
        }
        let add = search_symbols(&conn, "add", None, 10).unwrap();
        assert_eq!(add[0].name, "add");
        assert_eq!(add[0].language, "rust");
        assert_eq!(
            search_symbols(&conn, "say_hello", Some("fn"), 10).unwrap()[0].path,
            "tool.sh"
        );
        assert_eq!(
            search_symbols(&conn, "Thing", Some("class"), 10).unwrap()[0].language,
            "python"
        );
        assert!(search_symbols(&conn, "nope_not_here", None, 10)
            .unwrap()
            .is_empty());
        assert!(search_symbols(&conn, "add", Some("class"), 10)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn reindex_is_incremental_and_tracks_changes_and_deletes() {
        let (dir, conn) = fixture();
        let root = dir.path();
        index_repo(&conn, root).unwrap();
        // Nothing changed: everything skipped.
        let again = index_repo(&conn, root).unwrap();
        assert_eq!((again.indexed, again.unchanged), (0, 3), "{again:?}");
        // Edit one file: only it is re-parsed, and the new symbol appears.
        fs::write(
            root.join("mod.py"),
            "def compute():\n    return 1\n\ndef brand_new():\n    pass\n",
        )
        .unwrap();
        let edit =
            index_files(&conn, root, &["mod.py".to_string(), "tool.sh".to_string()]).unwrap();
        assert_eq!((edit.indexed, edit.unchanged), (1, 1), "{edit:?}");
        assert_eq!(
            search_symbols(&conn, "brand_new", None, 5).unwrap().len(),
            1
        );
        assert!(
            search_symbols(&conn, "Thing", None, 5).unwrap().is_empty(),
            "stale symbol must go"
        );
        // Delete a file: its rows are removed.
        fs::remove_file(root.join("tool.sh")).unwrap();
        let del = index_files(&conn, root, &["tool.sh".to_string()]).unwrap();
        assert_eq!(del.removed, 1);
        assert!(file_symbols(&conn, "tool.sh").unwrap().is_empty());
        // A full pass also prunes rows for files no longer present.
        fs::remove_file(root.join("mod.py")).unwrap();
        let prune = index_repo(&conn, root).unwrap();
        assert_eq!(prune.removed, 1, "{prune:?}");
    }

    #[test]
    fn unsupported_and_unreadable_paths_are_handled() {
        let (dir, conn) = fixture();
        let s = index_files(
            &conn,
            dir.path(),
            &["notes.txt".to_string(), "missing.rs".to_string()],
        )
        .unwrap();
        assert_eq!((s.indexed, s.unsupported, s.removed), (0, 1, 0), "{s:?}");
    }

    #[test]
    fn search_escapes_like_wildcards() {
        let (dir, conn) = fixture();
        index_repo(&conn, dir.path()).unwrap();
        assert!(search_symbols(&conn, "%", None, 10).unwrap().is_empty());
        assert!(search_symbols(&conn, "_", None, 10)
            .unwrap()
            .iter()
            .all(|s| s.name.contains('_')));
    }

    #[test]
    fn content_hash_is_stable() {
        assert_eq!(content_hash(b"abc"), content_hash(b"abc"));
        assert_ne!(content_hash(b"abc"), content_hash(b"abd"));
    }
}
