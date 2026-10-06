//! INFRA-8077 (INFRA-1583 Phase 1): the existence-query tools —
//! `code.find_symbol`, `code.callers_of`, `code.gap_history`.
//!
//! These exist to prevent the INFRA-1575 "feature missing" misdiagnosis class:
//! an agent concludes something never existed because one lookup came back empty,
//! when the symbol exists under another path or the gap's registry row was reaped.
//! Each tool therefore answers with an explicit, unambiguous shape instead of an
//! empty list.
//!
//! Response shapes (also documented in the crate README):
//!
//! ```text
//! code.find_symbol { name, kind? } ->
//!   { "symbol": str, "exists": bool, "count": n,
//!     "matches": [ { "path", "name", "kind", "line", "language", "doc_first_line" } ] }
//!
//! code.callers_of { symbol, limit? } ->
//!   { "symbol": str, "defined": bool, "count": n, "truncated": bool,
//!     "callers": [ { "path", "line", "text", "in_symbol": str|null } ] }
//!
//! code.gap_history { gap_id } ->
//!   { "gap_id": str, "status": "open"|"done"|"reaped"|"never_existed",
//!     "title": str|null, "shipped_pr": int|null,
//!     "closed_date": "YYYY-MM-DD"|null, "reaped_date": "YYYY-MM-DD"|null }
//! ```

use crate::SymbolRow;
use anyhow::Result;
use regex::Regex;
use rusqlite::{params, Connection, OpenFlags};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::Command;

/// `code.find_symbol`: exact (case-sensitive) name match across the index.
pub fn find_symbol(conn: &Connection, name: &str, kind: Option<&str>) -> Result<Value> {
    let mut stmt = conn.prepare(
        "SELECT s.path, s.name, s.kind, s.line, f.language, s.doc_first_line
         FROM symbols s JOIN files f ON f.path = s.path
         WHERE s.name = ?1 AND (?2 IS NULL OR s.kind = ?2)
         ORDER BY s.path, s.line",
    )?;
    let rows: Vec<SymbolRow> = stmt
        .query_map(params![name, kind], |r| {
            Ok(SymbolRow {
                path: r.get(0)?,
                name: r.get(1)?,
                kind: r.get(2)?,
                line: r.get(3)?,
                language: r.get(4)?,
                doc_first_line: r.get(5)?,
            })
        })?
        .filter_map(|r| r.ok())
        .collect();
    Ok(json!({
        "symbol": name,
        "exists": !rows.is_empty(),
        "count": rows.len(),
        "matches": rows,
    }))
}

fn call_pattern(language: &str, name: &str) -> Option<Regex> {
    let n = regex::escape(name);
    let pat = match language {
        "rust" => format!(r"\b{n}\s*(::<[^>]*>)?\s*\(|\b{n}!\s*[\(\[\{{]"),
        "python" => format!(r"\b{n}\s*\("),
        // Command position: line start, after ; & | ( $( then do, then the bare name.
        "bash" => format!(r"(^\s*|[;&|(]\s*|\$\(\s*|\b(?:then|do|else)\s+){n}(\s|$|;|\)|\|)"),
        _ => return None,
    };
    Regex::new(&pat).ok()
}

fn is_definition_line(language: &str, name: &str, line: &str) -> bool {
    let t = line.trim_start();
    let n = regex::escape(name);
    let def = match language {
        "rust" => format!(r"^(pub(\([^)]*\))?\s+)?(async\s+)?(const\s+)?(unsafe\s+)?fn\s+{n}\b"),
        "python" => format!(r"^(async\s+)?(def|class)\s+{n}\b"),
        "bash" => format!(r"^(function\s+{n}\b|{n}\s*\(\s*\))"),
        _ => return false,
    };
    Regex::new(&def).map(|r| r.is_match(t)).unwrap_or(false)
}

fn is_comment_line(language: &str, line: &str) -> bool {
    let t = line.trim_start();
    match language {
        "rust" => t.starts_with("//"),
        _ => t.starts_with('#'),
    }
}

/// `code.callers_of`: call sites of `symbol` in the indexed files. Textual
/// (tree-sitter gives us definitions, not references), so it is a call-pattern
/// scan that skips definitions and comments and names the enclosing symbol.
pub fn callers_of(
    conn: &Connection,
    repo_root: &Path,
    symbol: &str,
    limit: usize,
) -> Result<Value> {
    let defined = {
        let n: i64 = conn.query_row(
            "SELECT COUNT(*) FROM symbols WHERE name = ?1",
            params![symbol],
            |r| r.get(0),
        )?;
        n > 0
    };
    let files: Vec<(String, String)> = {
        let mut stmt = conn.prepare("SELECT path, language FROM files ORDER BY path")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        rows.filter_map(|r| r.ok()).collect()
    };
    let mut callers: Vec<Value> = Vec::new();
    let mut truncated = false;
    'files: for (path, language) in files {
        let Some(re) = call_pattern(&language, symbol) else {
            continue;
        };
        let Ok(text) = std::fs::read_to_string(repo_root.join(&path)) else {
            continue;
        };
        // Enclosing-symbol lookup: nearest indexed symbol at/above the call line.
        let syms: Vec<(i64, String)> = {
            let mut stmt =
                conn.prepare("SELECT line, name FROM symbols WHERE path = ?1 ORDER BY line")?;
            let rows = stmt.query_map(params![path], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
            })?;
            rows.filter_map(|r| r.ok()).collect()
        };
        for (i, line) in text.lines().enumerate() {
            let ln = (i + 1) as i64;
            if is_comment_line(&language, line)
                || is_definition_line(&language, symbol, line)
                || !re.is_match(line)
            {
                continue;
            }
            if callers.len() >= limit {
                truncated = true;
                break 'files;
            }
            let in_symbol = syms
                .iter()
                .take_while(|(l, _)| *l <= ln)
                .last()
                .map(|(_, n)| n.clone());
            callers.push(json!({
                "path": path,
                "line": ln,
                "text": line.trim().chars().take(200).collect::<String>(),
                "in_symbol": in_symbol,
            }));
        }
    }
    Ok(json!({
        "symbol": symbol,
        "defined": defined,
        "count": callers.len(),
        "truncated": truncated,
        "callers": callers,
    }))
}

fn state_db_path(repo_root: &Path) -> PathBuf {
    match std::env::var("CHUMP_STATE_DB") {
        Ok(p) if !p.trim().is_empty() => PathBuf::from(p),
        _ => repo_root.join(".chump").join("state.db"),
    }
}

fn epoch_to_date(secs: i64) -> Option<String> {
    // Civil-from-days (Howard Hinnant) — no chrono dependency for one date.
    let days = secs.div_euclid(86_400) + 719_468;
    let era = days.div_euclid(146_097);
    let doe = days.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (secs > 0).then(|| format!("{y:04}-{m:02}-{d:02}"))
}

/// The most recent commit (any branch) whose message mentions `gap_id`:
/// `(YYYY-MM-DD, shipped PR parsed from a trailing "(#N)" in the subject)`.
fn last_commit_mentioning(repo_root: &Path, gap_id: &str) -> Option<(String, Option<i64>)> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args([
            "log",
            "--all",
            "-1",
            "--fixed-strings",
            "--format=%cs%x09%s",
            "--grep",
            gap_id,
        ])
        .output()
        .ok()
        .filter(|o| o.status.success())?;
    let line = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let (date, subject) = line.split_once('\t')?;
    let pr = Regex::new(r"\(#(\d+)\)\s*$")
        .ok()
        .and_then(|re| re.captures(subject))
        .and_then(|c| c[1].parse().ok());
    Some((date.to_string(), pr))
}

/// `code.gap_history`: status of a gap id including the distinction a plain
/// registry lookup loses — `reaped` (the registry row is gone but git history
/// proves the gap existed) vs `never_existed`.
pub fn gap_history(repo_root: &Path, gap_id: &str) -> Result<Value> {
    let gap_id = gap_id.trim();
    let row =
        Connection::open_with_flags(state_db_path(repo_root), OpenFlags::SQLITE_OPEN_READ_ONLY)
            .ok()
            .and_then(|conn| {
                // closed_pr / closed_date are later migrations: select defensively.
                let full = conn.query_row(
                "SELECT status, title, closed_pr, closed_date, closed_at FROM gaps WHERE id = ?1",
                params![gap_id],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, Option<i64>>(2)?,
                        r.get::<_, Option<String>>(3)?,
                        r.get::<_, Option<i64>>(4)?,
                    ))
                },
            );
                match full {
                    Ok(v) => Some(Some(v)),
                    Err(rusqlite::Error::QueryReturnedNoRows) => Some(None),
                    Err(_) => conn
                        .query_row(
                            "SELECT status, title FROM gaps WHERE id = ?1",
                            params![gap_id],
                            |r| {
                                Ok((
                                    r.get::<_, String>(0)?,
                                    r.get::<_, String>(1)?,
                                    None,
                                    None,
                                    None,
                                ))
                            },
                        )
                        .ok()
                        .map(Some),
                }
            });
    if let Some(Some((status, title, closed_pr, closed_date, closed_at))) = row {
        let closed_date = closed_date
            .filter(|d| !d.trim().is_empty())
            .or_else(|| closed_at.and_then(epoch_to_date));
        let is_done = status == "done";
        return Ok(json!({
            "gap_id": gap_id,
            "status": if is_done { "done" } else if status == "open" { "open" } else { status.as_str() },
            "title": title,
            "shipped_pr": if is_done { closed_pr } else { None },
            "closed_date": if is_done { closed_date } else { None },
            "reaped_date": Value::Null,
        }));
    }
    // No registry row (or no registry at all): was it ever real?
    match last_commit_mentioning(repo_root, gap_id) {
        Some((date, pr)) => Ok(json!({
            "gap_id": gap_id,
            "status": "reaped",
            "title": Value::Null,
            "shipped_pr": pr,
            "closed_date": Value::Null,
            "reaped_date": date,
        })),
        None => Ok(json!({
            "gap_id": gap_id,
            "status": "never_existed",
            "title": Value::Null,
            "shipped_pr": Value::Null,
            "closed_date": Value::Null,
            "reaped_date": Value::Null,
        })),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn indexed_repo() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::write(
            root.join("a.rs"),
            "pub fn helper() -> i32 { 1 }\n// helper() mentioned in a comment\npub fn caller_one() -> i32 {\n    helper() + 1\n}\npub fn caller_two() { let _ = helper::<u8>; println!(\"{}\", helper()); }\n",
        )
        .unwrap();
        fs::write(
            root.join("b.py"),
            "def helper():\n    return 2\n\ndef use_it():\n    return helper()\n",
        )
        .unwrap();
        fs::write(root.join("c.sh"), "#!/usr/bin/env bash\nhelper() { :; }\nrun() {\n  helper\n  echo done && helper\n}\n# helper in a comment\n").unwrap();
        let conn = crate::open_db(&root.join(".chump/code_index.db")).unwrap();
        crate::index_repo(&conn, root).unwrap();
        (dir, conn)
    }

    #[test]
    fn find_symbol_reports_existence_across_languages_and_misses_cleanly() {
        let (_d, conn) = indexed_repo();
        let hit = find_symbol(&conn, "helper", None).unwrap();
        assert_eq!(hit["exists"], true);
        assert_eq!(hit["count"], 3, "{hit}");
        let langs: Vec<&str> = hit["matches"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["language"].as_str().unwrap())
            .collect();
        assert_eq!(langs, ["rust", "python", "bash"]);
        let rust_only = find_symbol(&conn, "helper", Some("fn")).unwrap();
        assert!(rust_only["count"].as_i64().unwrap() >= 1);
        let miss = find_symbol(&conn, "no_such_symbol", None).unwrap();
        assert_eq!(
            (miss["exists"].clone(), miss["count"].clone()),
            (json!(false), json!(0))
        );
        assert!(miss["matches"].as_array().unwrap().is_empty());
        // Exact, case-sensitive: a substring or different case is not a hit.
        assert_eq!(find_symbol(&conn, "help", None).unwrap()["exists"], false);
        assert_eq!(find_symbol(&conn, "Helper", None).unwrap()["exists"], false);
    }

    #[test]
    fn callers_of_finds_call_sites_not_definitions_or_comments() {
        let (d, conn) = indexed_repo();
        let res = callers_of(&conn, d.path(), "helper", 50).unwrap();
        assert_eq!(res["defined"], true);
        let callers = res["callers"].as_array().unwrap();
        let sites: Vec<(String, i64)> = callers
            .iter()
            .map(|c| {
                (
                    c["path"].as_str().unwrap().to_string(),
                    c["line"].as_i64().unwrap(),
                )
            })
            .collect();
        // rust: line 4 (in caller_one) and line 6 (in caller_two); python: line 5; bash: lines 4 and 5.
        assert!(sites.contains(&("a.rs".into(), 4)), "{sites:?}");
        assert!(sites.contains(&("a.rs".into(), 6)), "{sites:?}");
        assert!(sites.contains(&("b.py".into(), 5)), "{sites:?}");
        assert!(
            sites.contains(&("c.sh".into(), 4)) && sites.contains(&("c.sh".into(), 5)),
            "{sites:?}"
        );
        // Definitions and comment lines are not callers.
        assert!(
            !sites.contains(&("a.rs".into(), 1)) && !sites.contains(&("a.rs".into(), 2)),
            "{sites:?}"
        );
        assert!(
            !sites.contains(&("b.py".into(), 1))
                && !sites.contains(&("c.sh".into(), 2))
                && !sites.contains(&("c.sh".into(), 7)),
            "{sites:?}"
        );
        let in_sym: Vec<_> = callers
            .iter()
            .filter(|c| c["path"] == "a.rs" && c["line"] == 4)
            .map(|c| c["in_symbol"].clone())
            .collect();
        assert_eq!(in_sym, [json!("caller_one")]);
    }

    #[test]
    fn callers_of_handles_limit_and_undefined_symbols() {
        let (d, conn) = indexed_repo();
        let capped = callers_of(&conn, d.path(), "helper", 2).unwrap();
        assert_eq!(capped["count"], 2);
        assert_eq!(capped["truncated"], true);
        let none = callers_of(&conn, d.path(), "ghost_fn", 10).unwrap();
        assert_eq!(
            (
                none["defined"].clone(),
                none["count"].clone(),
                none["truncated"].clone()
            ),
            (json!(false), json!(0), json!(false))
        );
    }

    #[test]
    fn gap_history_distinguishes_open_done_reaped_and_never_existed() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let git = |args: &[&str]| {
            let o = Command::new("git")
                .arg("-C")
                .arg(root)
                .args([
                    "-c",
                    "user.email=t@t",
                    "-c",
                    "user.name=t",
                    "-c",
                    "commit.gpgsign=false",
                ])
                .args(args)
                .output()
                .unwrap();
            assert!(o.status.success(), "git {args:?}");
        };
        git(&["init", "-q"]);
        git(&[
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "GHOST-9: removed feature (#77)",
        ]);
        fs::create_dir_all(root.join(".chump")).unwrap();
        let db = Connection::open(root.join(".chump/state.db")).unwrap();
        db.execute_batch(
            "CREATE TABLE gaps (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'open',
                                closed_at INTEGER, closed_date TEXT NOT NULL DEFAULT '', closed_pr INTEGER);
             INSERT INTO gaps (id, title, status) VALUES ('OPEN-1', 'still open', 'open');
             INSERT INTO gaps (id, title, status, closed_at, closed_date, closed_pr) VALUES ('DONE-1', 'shipped', 'done', 1760000000, '2026-10-09', 4321);
             INSERT INTO gaps (id, title, status, closed_at, closed_date, closed_pr) VALUES ('DONE-2', 'no date col', 'done', 1760000000, '', 55);",
        )
        .unwrap();
        drop(db);
        let open = gap_history(root, "OPEN-1").unwrap();
        assert_eq!(
            (
                open["status"].clone(),
                open["shipped_pr"].clone(),
                open["closed_date"].clone()
            ),
            (json!("open"), Value::Null, Value::Null)
        );
        let done = gap_history(root, "DONE-1").unwrap();
        assert_eq!(
            (
                done["status"].clone(),
                done["shipped_pr"].clone(),
                done["closed_date"].clone()
            ),
            (json!("done"), json!(4321), json!("2026-10-09"))
        );
        // closed_date empty -> derived from closed_at.
        assert_eq!(
            gap_history(root, "DONE-2").unwrap()["closed_date"],
            json!(epoch_to_date(1_760_000_000).unwrap())
        );
        let reaped = gap_history(root, "GHOST-9").unwrap();
        assert_eq!(reaped["status"], "reaped");
        assert_eq!(reaped["shipped_pr"], 77);
        assert!(reaped["reaped_date"].as_str().unwrap().starts_with("20"));
        let never = gap_history(root, "NOPE-1").unwrap();
        assert_eq!(
            (never["status"].clone(), never["reaped_date"].clone()),
            (json!("never_existed"), Value::Null)
        );
    }

    #[test]
    fn epoch_to_date_matches_known_dates() {
        assert_eq!(epoch_to_date(1_760_000_000).as_deref(), Some("2025-10-09"));
        assert_eq!(epoch_to_date(951_782_400).as_deref(), Some("2000-02-29"));
        assert_eq!(epoch_to_date(0), None);
    }
}
