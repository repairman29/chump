//! INFRA-8079 (INFRA-1583 Phase 3): the advanced-lookup tools —
//! `code.trait_impls`, `code.symbol_history`, `code.dead_code_scan`.
//!
//! Like Phase 1 these answer with explicit shapes rather than empty lists, and
//! are textual/git-backed (the tree-sitter index supplies definitions, not
//! references). Response shapes (also documented in the crate README):
//!
//! ```text
//! code.trait_impls { trait, limit? } ->
//!   { "trait": str, "defined": bool, "count": n, "truncated": bool,
//!     "impls": [ { "path", "line", "type", "kind": "impl"|"subclass", "language" } ] }
//!
//! code.symbol_history { symbol, limit? } ->
//!   { "symbol": str, "count": n, "truncated": bool,
//!     "first_seen": "YYYY-MM-DD"|null, "last_changed": "YYYY-MM-DD"|null,
//!     "commits": [ { "sha", "date", "subject" } ] }          // newest first
//!
//! code.dead_code_scan { reasons?, limit? } ->
//!   { "count": n, "total": n, "truncated": bool, "by_reason": { reason: n },
//!     "findings": [ { "symbol", "file", "line", "location": "file:line",
//!                     "reason": "no_callers"|"no_emitters"|"registered_unused_route",
//!                     "kind" } ] }
//! ```
//!
//! `code.dead_code_scan` reasons:
//! - `no_callers`: an indexed `fn` whose name occurs nowhere else in the code
//!   files (a name used exactly once is only its own definition). `main`, test
//!   helpers and anything under a `tests/` directory are skipped.
//! - `no_emitters`: an event kind registered in
//!   `docs/observability/EVENT_REGISTRY.yaml` that no code file mentions.
//! - `registered_unused_route`: an HTTP route registered with `.route("/path", …)`
//!   whose path (up to the first parameter segment) is referenced nowhere else —
//!   no client, script or test calls it.

use crate::SymbolRow;
use anyhow::Result;
use regex::Regex;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

/// `code.trait_impls`: implementors of `trait_name`.
///
/// Rust: single-line `impl [<..>] Trait[<..>] for Type` headers. Python: classes
/// listing `Trait` among their bases (reported as `kind: "subclass"`).
pub fn trait_impls(
    conn: &Connection,
    repo_root: &Path,
    trait_name: &str,
    limit: usize,
) -> Result<Value> {
    let defined = {
        let n: i64 = conn.query_row(
            "SELECT COUNT(*) FROM symbols WHERE name = ?1",
            params![trait_name],
            |r| r.get(0),
        )?;
        n > 0
    };
    let esc = regex::escape(trait_name);
    let rust_re = Regex::new(&format!(
        r"^\s*(?:unsafe\s+)?impl\b.*?(?:^|[\s<:,]){esc}\s*(?:<[^{{]*?>)?\s+for\s+([^\s{{]+)"
    ))?;
    let py_re = Regex::new(&format!(r"^\s*class\s+(\w+)\s*\(([^)]*\b{esc}\b[^)]*)\)"))?;
    let files: Vec<(String, String)> = {
        let mut stmt = conn.prepare(
            "SELECT path, language FROM files WHERE language IN ('rust','python') ORDER BY path",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        rows.filter_map(|r| r.ok()).collect()
    };
    let mut impls: Vec<Value> = Vec::new();
    let mut truncated = false;
    'files: for (path, language) in files {
        let Ok(text) = std::fs::read_to_string(repo_root.join(&path)) else {
            continue;
        };
        for (i, line) in text.lines().enumerate() {
            let hit = if language == "rust" {
                let t = line.trim_start();
                if t.starts_with("//") {
                    continue;
                }
                rust_re
                    .captures(line)
                    .map(|c| (c[1].trim_end_matches(',').to_string(), "impl"))
            } else {
                py_re.captures(line).map(|c| (c[1].to_string(), "subclass"))
            };
            let Some((ty, kind)) = hit else { continue };
            if impls.len() >= limit {
                truncated = true;
                break 'files;
            }
            impls.push(json!({
                "path": path,
                "line": (i + 1) as i64,
                "type": ty,
                "kind": kind,
                "language": language,
            }));
        }
    }
    Ok(json!({
        "trait": trait_name,
        "defined": defined,
        "count": impls.len(),
        "truncated": truncated,
        "impls": impls,
    }))
}

/// `code.symbol_history`: commits that added or removed occurrences of `symbol`
/// (git pickaxe, `-S`), newest first, with first/last dates.
pub fn symbol_history(repo_root: &Path, symbol: &str, limit: usize) -> Result<Value> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["log", "--format=%H%x09%cs%x09%s", "--fixed-strings", "-S"])
        .arg(symbol)
        .output()
        .ok()
        .filter(|o| o.status.success());
    let commits: Vec<(String, String, String)> = match out {
        Some(o) => String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter_map(|l| {
                let mut p = l.splitn(3, '\t');
                Some((
                    p.next()?.to_string(),
                    p.next()?.to_string(),
                    p.next()?.to_string(),
                ))
            })
            .collect(),
        None => Vec::new(),
    };
    let first_seen = commits.last().map(|c| c.1.clone());
    let last_changed = commits.first().map(|c| c.1.clone());
    let truncated = commits.len() > limit;
    let shown: Vec<Value> = commits
        .iter()
        .take(limit)
        .map(|(sha, date, subject)| {
            json!({"sha": sha.chars().take(12).collect::<String>(), "date": date, "subject": subject})
        })
        .collect();
    Ok(json!({
        "symbol": symbol,
        "count": shown.len(),
        "truncated": truncated,
        "first_seen": first_seen,
        "last_changed": last_changed,
        "commits": shown,
    }))
}

const CODE_EXTS: [&str; 9] = ["rs", "sh", "bash", "py", "js", "mjs", "ts", "tsx", "html"];
const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024;

fn code_files(repo_root: &Path) -> Vec<String> {
    let git = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["ls-files", "-z"])
        .output()
        .ok()
        .filter(|o| o.status.success());
    let mut v: Vec<String> = match git {
        Some(o) => String::from_utf8_lossy(&o.stdout)
            .split('\0')
            .filter(|p| {
                Path::new(p)
                    .extension()
                    .and_then(|x| x.to_str())
                    .is_some_and(|x| CODE_EXTS.contains(&x))
            })
            .map(String::from)
            .collect(),
        None => {
            let mut out = Vec::new();
            walk_code(repo_root, repo_root, &mut out);
            out
        }
    };
    v.sort();
    v
}

fn walk_code(dir: &Path, root: &Path, out: &mut Vec<String>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        if p.is_dir() {
            if !crate::is_skip_dir(&name) {
                walk_code(&p, root, out);
            }
        } else if p
            .extension()
            .and_then(|x| x.to_str())
            .is_some_and(|x| CODE_EXTS.contains(&x))
        {
            if let Ok(rel) = p.strip_prefix(root) {
                out.push(rel.to_string_lossy().into_owned());
            }
        }
    }
}

fn read_code(repo_root: &Path, rel: &str) -> Option<String> {
    let p = repo_root.join(rel);
    if std::fs::metadata(&p).ok()?.len() > MAX_FILE_BYTES {
        return None;
    }
    std::fs::read_to_string(p).ok()
}

fn is_test_path(path: &str) -> bool {
    path.starts_with("tests/") || path.contains("/tests/")
}

/// `code.dead_code_scan`: see the module docs for the three reasons.
pub fn dead_code_scan(
    conn: &Connection,
    repo_root: &Path,
    reasons: &[String],
    limit: usize,
) -> Result<Value> {
    let want = |r: &str| reasons.is_empty() || reasons.iter().any(|x| x == r);
    let texts: Vec<(String, String)> = code_files(repo_root)
        .into_iter()
        .filter_map(|p| read_code(repo_root, &p).map(|t| (p, t)))
        .collect();

    // Identifier occurrence counts across every code file.
    let mut tokens: HashMap<&str, u32> = HashMap::new();
    let ident = Regex::new(r"[A-Za-z_][A-Za-z0-9_]*")?;
    for (_, text) in &texts {
        for m in ident.find_iter(text) {
            *tokens.entry(m.as_str()).or_insert(0) += 1;
        }
    }

    let mut findings: Vec<(u8, SymbolRowLite)> = Vec::new();

    if want("no_callers") {
        let mut stmt = conn.prepare(
            "SELECT s.path, s.name, s.kind, s.line, f.language, s.doc_first_line
             FROM symbols s JOIN files f ON f.path = s.path
             WHERE s.kind = 'fn' ORDER BY s.path, s.line",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(SymbolRow {
                path: r.get(0)?,
                name: r.get(1)?,
                kind: r.get(2)?,
                line: r.get(3)?,
                language: r.get(4)?,
                doc_first_line: r.get(5)?,
            })
        })?;
        for row in rows.filter_map(|r| r.ok()) {
            if row.name == "main" || row.name.starts_with("test") || is_test_path(&row.path) {
                continue;
            }
            if tokens.get(row.name.as_str()).copied().unwrap_or(0) <= 1 {
                findings.push((
                    0,
                    SymbolRowLite::new(row.name, row.path, row.line, "no_callers", "fn"),
                ));
            }
        }
    }

    if want("no_emitters") {
        let reg = repo_root.join("docs/observability/EVENT_REGISTRY.yaml");
        if let Ok(text) = std::fs::read_to_string(&reg) {
            let kind_re = Regex::new(r"^\s*-\s+kind:\s*([A-Za-z0-9_]+)")?;
            for (i, line) in text.lines().enumerate() {
                if let Some(c) = kind_re.captures(line) {
                    let kind = c[1].to_string();
                    if tokens.get(kind.as_str()).copied().unwrap_or(0) == 0 {
                        findings.push((
                            1,
                            SymbolRowLite::new(
                                kind,
                                "docs/observability/EVENT_REGISTRY.yaml".into(),
                                (i + 1) as i64,
                                "no_emitters",
                                "event_kind",
                            ),
                        ));
                    }
                }
            }
        }
    }

    if want("registered_unused_route") {
        let route_re = Regex::new(r#"\.route\(\s*"(/[^"]*)""#)?;
        for (path, text) in texts.iter().filter(|(p, _)| p.ends_with(".rs")) {
            for (i, line) in text.lines().enumerate() {
                if line.trim_start().starts_with("//") {
                    continue;
                }
                for c in route_re.captures_iter(line) {
                    let route = c[1].to_string();
                    let prefix = route_prefix(&route);
                    if prefix.is_empty() {
                        continue;
                    }
                    let own = text.matches(prefix).count();
                    let elsewhere: usize = texts
                        .iter()
                        .filter(|(p, _)| p != path)
                        .map(|(_, t)| t.matches(prefix).count())
                        .sum();
                    if own <= 1 && elsewhere == 0 {
                        findings.push((
                            2,
                            SymbolRowLite::new(
                                route,
                                path.clone(),
                                (i + 1) as i64,
                                "registered_unused_route",
                                "route",
                            ),
                        ));
                    }
                }
            }
        }
    }

    findings.sort_by(|a, b| (a.0, &a.1.file, a.1.line).cmp(&(b.0, &b.1.file, b.1.line)));
    let total = findings.len();
    let mut by_reason: serde_json::Map<String, Value> = serde_json::Map::new();
    for (_, f) in &findings {
        let n = by_reason
            .get(f.reason)
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        by_reason.insert(f.reason.to_string(), json!(n + 1));
    }
    let shown: Vec<Value> = findings
        .into_iter()
        .take(limit)
        .map(|(_, f)| {
            json!({
                "symbol": f.symbol,
                "file": f.file,
                "line": f.line,
                "location": format!("{}:{}", f.file, f.line),
                "reason": f.reason,
                "kind": f.kind,
            })
        })
        .collect();
    Ok(json!({
        "count": shown.len(),
        "total": total,
        "truncated": total > shown.len(),
        "by_reason": by_reason,
        "findings": shown,
    }))
}

/// The literal part of a route up to its first parameter segment
/// (`/api/gaps/{id}` -> `/api/gaps/`, `/api/ping` -> `/api/ping`).
fn route_prefix(route: &str) -> &str {
    let cut = route
        .find(|c| c == '{' || c == ':' || c == '*')
        .unwrap_or(route.len());
    let p = &route[..cut];
    if p == "/" {
        ""
    } else {
        p
    }
}

struct SymbolRowLite {
    symbol: String,
    file: String,
    line: i64,
    reason: &'static str,
    kind: &'static str,
}

impl SymbolRowLite {
    fn new(
        symbol: String,
        file: String,
        line: i64,
        reason: &'static str,
        kind: &'static str,
    ) -> Self {
        Self {
            symbol,
            file,
            line,
            reason,
            kind,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn repo() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("docs/observability")).unwrap();
        fs::write(
            root.join("a.rs"),
            "pub trait Shape { fn area(&self) -> f64; }\n\
             pub struct Sq;\n\
             impl Shape for Sq { fn area(&self) -> f64 { 1.0 } }\n\
             impl<T> Shape for Vec<T> { fn area(&self) -> f64 { 0.0 } }\n\
             // impl Shape for Commented {}\n\
             pub fn used_fn() -> i32 { 1 }\n\
             pub fn orphan_fn() -> i32 { 2 }\n\
             pub fn main_user() -> i32 { used_fn() }\n\
             pub fn router() { app.route(\"/api/live\", get(h)).route(\"/api/dead/{id}\", get(h)); }\n",
        )
        .unwrap();
        fs::write(
            root.join("b.py"),
            "class Impl(Base, Shape):\n    pass\nclass Other(Base):\n    pass\n",
        )
        .unwrap();
        fs::write(root.join("client.js"), "fetch('/api/live')\n").unwrap();
        fs::write(
            root.join("docs/observability/EVENT_REGISTRY.yaml"),
            "events:\n  - kind: emitted_kind\n  - kind: ghost_kind\n",
        )
        .unwrap();
        fs::write(root.join("emit.sh"), "echo emitted_kind\n").unwrap();
        let conn = crate::open_db(&root.join(".chump/code_index.db")).unwrap();
        crate::index_repo(&conn, root).unwrap();
        (dir, conn)
    }

    #[test]
    fn trait_impls_finds_rust_impls_and_python_subclasses_skipping_comments() {
        let (d, conn) = repo();
        let v = trait_impls(&conn, d.path(), "Shape", 50).unwrap();
        assert_eq!(v["defined"], true, "{v}");
        let impls = v["impls"].as_array().unwrap();
        let tys: Vec<&str> = impls.iter().map(|i| i["type"].as_str().unwrap()).collect();
        assert_eq!(tys, vec!["Sq", "Vec<T>", "Impl"], "{v}");
        assert_eq!(impls[0]["line"], 3);
        assert_eq!(impls[2]["kind"], "subclass");
        let none = trait_impls(&conn, d.path(), "Nope", 50).unwrap();
        assert_eq!(none["defined"], false);
        assert_eq!(none["count"], 0);
        let cut = trait_impls(&conn, d.path(), "Shape", 1).unwrap();
        assert_eq!(cut["truncated"], true);
        assert_eq!(cut["count"], 1);
    }

    #[test]
    fn symbol_history_lists_pickaxe_commits_newest_first() {
        let dir = tempfile::tempdir().unwrap();
        let r = dir.path();
        let git = |args: &[&str]| {
            let ok = Command::new("git")
                .arg("-C")
                .arg(r)
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
                .unwrap()
                .status
                .success();
            assert!(ok, "git {args:?}");
        };
        git(&["init", "-q"]);
        fs::write(r.join("f.rs"), "fn alpha() {}\n").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", "add alpha"]);
        fs::write(r.join("f.rs"), "fn alpha() {}\nfn beta() {}\n").unwrap();
        git(&["commit", "-aq", "-m", "add beta"]);
        fs::write(r.join("f.rs"), "fn beta() {}\n").unwrap();
        git(&["commit", "-aq", "-m", "remove alpha"]);
        let v = symbol_history(r, "alpha", 10).unwrap();
        let subjects: Vec<&str> = v["commits"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["subject"].as_str().unwrap())
            .collect();
        assert_eq!(subjects, vec!["remove alpha", "add alpha"], "{v}");
        assert_eq!(v["commits"][0]["sha"].as_str().unwrap().len(), 12);
        assert!(v["first_seen"].is_string() && v["last_changed"].is_string());
        let never = symbol_history(r, "zzz_never", 10).unwrap();
        assert_eq!(never["count"], 0);
        assert!(never["first_seen"].is_null());
        let cut = symbol_history(r, "alpha", 1).unwrap();
        assert_eq!(cut["truncated"], true);
    }

    #[test]
    fn dead_code_scan_reports_each_reason_with_location() {
        let (d, conn) = repo();
        // git ls-files needs a repo; the scan falls back to a directory walk without one.
        let v = dead_code_scan(&conn, d.path(), &[], 100).unwrap();
        let f = v["findings"].as_array().unwrap();
        let find = |reason: &str, sym: &str| {
            f.iter()
                .any(|x| x["reason"] == reason && x["symbol"] == sym)
        };
        assert!(find("no_callers", "orphan_fn"), "{v}");
        assert!(!find("no_callers", "used_fn"), "{v}");
        assert!(find("no_emitters", "ghost_kind"), "{v}");
        assert!(!find("no_emitters", "emitted_kind"), "{v}");
        assert!(find("registered_unused_route", "/api/dead/{id}"), "{v}");
        assert!(!find("registered_unused_route", "/api/live"), "{v}");
        let one = f.iter().find(|x| x["symbol"] == "ghost_kind").unwrap();
        assert_eq!(one["location"], "docs/observability/EVENT_REGISTRY.yaml:3");
        assert_eq!(v["total"], f.len());
        // reasons filter + limit
        let only = dead_code_scan(&conn, d.path(), &["no_emitters".to_string()], 100).unwrap();
        assert!(only["findings"]
            .as_array()
            .unwrap()
            .iter()
            .all(|x| x["reason"] == "no_emitters"));
        let cut = dead_code_scan(&conn, d.path(), &[], 1).unwrap();
        assert_eq!(cut["count"], 1);
        assert_eq!(cut["truncated"], true);
    }

    #[test]
    fn route_prefix_cuts_at_the_first_parameter() {
        assert_eq!(route_prefix("/api/gaps/{id}"), "/api/gaps/");
        assert_eq!(route_prefix("/api/ping"), "/api/ping");
        assert_eq!(route_prefix("/"), "");
    }
}
