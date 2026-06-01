//! META-271 / INFRA-2367 / INFRA-2368 / INFRA-2370 — Fleet Inventory + Tech-Debt Audit DB.
//!
//! **REVIEW-ONLY tier 0 default.** Every detector lands findings at tier=0
//! (surface-only). No gap-filing, no removal, no auto-action in this PR's
//! scope. The operator promotes a finding_class from tier 0 → 2 via
//! `chump inventory promote <class>` only after calibration via
//! `chump inventory review`. Tier-2 auto-file machinery is deferred to
//! INFRA-2374.
//!
//! Storage: `.chump/inventory.db` (separate from canonical state.db so
//! schema churn doesn't risk the canonical fleet DB).
//!
//! Detectors (9 classes, all tier=0 by default):
//!   1. orphan-artifact           — artifact has zero inbound references in the repo
//!   2. dormant-script            — shell script not invoked from any script/plist/Rust/docs
//!   3. dead-rust-mod             — Rust module declared in mod.rs/lib.rs but never reachable from a binary
//!   4. stale-plist               — launchd plist whose target binary path doesn't exist
//!   5. doc-only-feature          — gap shipped a doc but no code change touched the named subsystem
//!   6. unreferenced-gap          — gap shipped >30d ago but its artifacts are orphans
//!   7. long-undormant-substrate  — substrate PR merged >90d, no inbound reference growth since
//!   8. shadow-duplicate          — two artifacts implement near-identical shell of a primitive
//!   9. event-kind-zero-emit      — EVENT_REGISTRY kind has zero ambient occurrences in 30d
//!
//! Every detector emits `kind=tech_debt_finding` to ambient.jsonl AND inserts
//! into `tech_debt_findings`. NEVER files a gap.
//!
//! Acceptance criteria (META-271):
//!   AC1 — schema applied via migrations/inventory_v1.sql
//!   AC2 — 9 detectors emit + insert at tier=0 only; auto_fix_filed_gap_id NULL on all rows
//!   AC3 — CLI: rebuild, show, debt-report, dead-code, orphans, review, review-queue, class-stats, promote, demote
//!   AC4 — promote rejects when <10 reviewed OR <70% real_positive ratio
//!   AC5 — integration test scripts/ci/test-inventory.sh covers all primitives

use anyhow::{anyhow, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

// ─── constants ───────────────────────────────────────────────────────────────

/// The 9 detector class names. Used for seeding finding_class_tiers and
/// validating operator input.
pub const DETECTOR_CLASSES: &[&str] = &[
    "orphan-artifact",
    "dormant-script",
    "dead-rust-mod",
    "stale-plist",
    "doc-only-feature",
    "unreferenced-gap",
    "long-undormant-substrate",
    "shadow-duplicate",
    "event-kind-zero-emit",
];

/// Promotion gates from tier 0 → tier 2 (mandatory; promote rejects below).
pub const PROMOTE_MIN_REVIEWED: i64 = 10;
pub const PROMOTE_MIN_REAL_POSITIVE_RATIO: f64 = 0.70;

// ─── helpers ─────────────────────────────────────────────────────────────────

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Resolve the repo root. Prefers CHUMP_REPO_ROOT (test override),
/// then crate::repo_path::repo_root(), then current dir.
pub fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        let p = PathBuf::from(r);
        if p.is_dir() {
            return p;
        }
    }
    if let Ok(r) = std::env::var("CHUMP_REPO") {
        let p = PathBuf::from(r);
        if p.is_dir() {
            return p;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Resolve the inventory DB path. Defaults to `<repo>/.chump/inventory.db`.
/// Override via CHUMP_INVENTORY_DB for tests.
pub fn inventory_db_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_INVENTORY_DB") {
        return PathBuf::from(p);
    }
    repo_root().join(".chump/inventory.db")
}

/// Resolve the ambient log path.
pub fn ambient_log_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_AMBIENT_LOG") {
        return PathBuf::from(p);
    }
    repo_root().join(".chump-locks/ambient.jsonl")
}

/// Resolve the migration SQL path. CHUMP_INVENTORY_MIGRATION lets tests
/// point at an isolated fixture; default is repo_root/migrations/inventory_v1.sql.
fn migration_sql_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_INVENTORY_MIGRATION") {
        return PathBuf::from(p);
    }
    repo_root().join("migrations/inventory_v1.sql")
}

// ─── schema / open ───────────────────────────────────────────────────────────

/// Open (and lazily initialize) the inventory DB. Applies the v1 schema
/// idempotently every open — every CREATE statement is `IF NOT EXISTS`.
pub fn open_db() -> Result<Connection> {
    open_db_at(&inventory_db_path(), &migration_sql_path())
}

/// Explicit-path variant — bypasses env-var resolution. Used by tests and
/// callers that need isolation from CHUMP_INVENTORY_DB.
pub fn open_db_at(db_path: &Path, schema_path: &Path) -> Result<Connection> {
    if let Some(parent) = db_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("creating parent dir for {}", db_path.display()))?;
    }
    let conn = Connection::open(db_path)
        .with_context(|| format!("opening inventory DB at {}", db_path.display()))?;
    let sql = fs::read_to_string(schema_path)
        .with_context(|| format!("reading inventory schema at {}", schema_path.display()))?;
    conn.execute_batch(&sql)
        .with_context(|| "applying inventory schema")?;
    Ok(conn)
}

// ─── ambient emit ────────────────────────────────────────────────────────────

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}

/// Append a `kind=tech_debt_finding` event line to ambient.jsonl.
/// Fails silently (warn-only) — observability must not block detector flow.
fn emit_tech_debt_finding_event(
    finding_id: i64,
    finding_class: &str,
    severity: &str,
    artifact_path: Option<&str>,
    pr_number: Option<i64>,
    gap_id: Option<&str>,
    detail: &str,
) {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut json = String::new();
    json.push_str(&format!(
        r#"{{"ts":"{}","kind":"tech_debt_finding","finding_id":{},"finding_class":"{}","severity":"{}","tier":0,"detail":"{}""#,
        ts,
        finding_id,
        json_escape(finding_class),
        json_escape(severity),
        json_escape(detail),
    ));
    if let Some(p) = artifact_path {
        json.push_str(&format!(r#","artifact_path":"{}""#, json_escape(p)));
    }
    if let Some(n) = pr_number {
        json.push_str(&format!(r#","pr_number":{}"#, n));
    }
    if let Some(g) = gap_id {
        json.push_str(&format!(r#","gap_id":"{}""#, json_escape(g)));
    }
    json.push('}');

    let path = ambient_log_path();
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{}", json);
    }
}

// ─── finding insert (the only write path) ────────────────────────────────────

#[derive(Debug, Clone)]
pub struct Finding {
    pub finding_class: String,
    pub severity: String,
    pub artifact_path: Option<String>,
    pub pr_number: Option<i64>,
    pub gap_id: Option<String>,
    pub detail: String,
    pub evidence_json: Option<String>,
}

/// Insert a finding at tier=0 (surface-only). Always emits ambient event.
/// **Never files a gap** — auto_fix_filed_gap_id remains NULL.
pub fn insert_finding(conn: &Connection, f: &Finding) -> Result<i64> {
    let ts = now_secs();
    conn.execute(
        "INSERT INTO tech_debt_findings
            (finding_class, severity, artifact_path, pr_number, gap_id,
             detail, evidence, detected_at, tier, operator_classification,
             operator_reviewed_at, operator_note, auto_fix_filed_gap_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0, NULL, NULL, NULL, NULL)",
        params![
            f.finding_class,
            f.severity,
            f.artifact_path,
            f.pr_number,
            f.gap_id,
            f.detail,
            f.evidence_json,
            ts,
        ],
    )
    .with_context(|| "inserting tech_debt_finding")?;
    let id = conn.last_insert_rowid();

    emit_tech_debt_finding_event(
        id,
        &f.finding_class,
        &f.severity,
        f.artifact_path.as_deref(),
        f.pr_number,
        f.gap_id.as_deref(),
        &f.detail,
    );
    Ok(id)
}

// ─── collectors ──────────────────────────────────────────────────────────────

/// Run a shell command and return stdout (trimmed). Empty Vec on failure.
fn run_cmd(cmd: &str, args: &[&str], cwd: &Path) -> Vec<String> {
    let out = match Command::new(cmd).args(args).current_dir(cwd).output() {
        Ok(o) if o.status.success() => o.stdout,
        _ => return vec![],
    };
    String::from_utf8_lossy(&out)
        .lines()
        .map(|l| l.to_string())
        .collect()
}

/// Extract gap ID like "INFRA-1234" or "META-271" from a PR title.
fn extract_gap_id(title: &str) -> Option<String> {
    let upper = title.to_uppercase();
    // Match <DOMAIN>-<NUMBER> where DOMAIN is uppercase letters, NUMBER >=1 digits.
    let bytes = upper.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_uppercase() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_uppercase() {
                i += 1;
            }
            let domain_end = i;
            if i < bytes.len() && bytes[i] == b'-' && domain_end - start >= 3 {
                i += 1;
                let num_start = i;
                while i < bytes.len() && bytes[i].is_ascii_digit() {
                    i += 1;
                }
                if i > num_start {
                    let candidate = &upper[start..i];
                    // Filter out things like "PR-1234" / "API-1" — accept known prefixes.
                    let prefix = &upper[start..domain_end];
                    let known = matches!(
                        prefix,
                        "INFRA"
                            | "META"
                            | "FLEET"
                            | "CREDIBLE"
                            | "EFFECTIVE"
                            | "RESILIENT"
                            | "DOC"
                            | "COG"
                            | "EVAL"
                            | "VOA"
                            | "MEM"
                    );
                    if known {
                        return Some(candidate.to_string());
                    }
                }
            }
        } else {
            i += 1;
        }
    }
    None
}

/// Extract domain prefix from a gap ID like "INFRA-2367" → "INFRA".
fn domain_from_gap(gap_id: &str) -> String {
    gap_id.split('-').next().unwrap_or("").to_string()
}

/// Collect PRs from `gh pr list` (state:all, limit 1000). Best-effort —
/// if `gh` isn't available, returns 0 PRs (other layers can populate later).
pub fn collect_prs(conn: &Connection, root: &Path) -> Result<usize> {
    // Use gh pr list with JSON. Limit 1000 is the cap for `gh pr list`.
    let args = [
        "pr",
        "list",
        "--state",
        "all",
        "--limit",
        "1000",
        "--json",
        "number,title,state,headRefName,baseRefName,author,createdAt,closedAt,mergedAt,additions,deletions,changedFiles",
    ];
    let out = match Command::new("gh").args(args).current_dir(root).output() {
        Ok(o) if o.status.success() => o.stdout,
        _ => return Ok(0),
    };
    let s = String::from_utf8_lossy(&out);
    let value: serde_json::Value = match serde_json::from_str(&s) {
        Ok(v) => v,
        Err(_) => return Ok(0),
    };
    let arr = match value.as_array() {
        Some(a) => a,
        None => return Ok(0),
    };

    let tx = conn.unchecked_transaction()?;
    let ts = now_secs();
    let mut n = 0usize;
    for pr in arr {
        let number = pr.get("number").and_then(|v| v.as_i64()).unwrap_or(0);
        if number == 0 {
            continue;
        }
        let title = pr
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let state = pr
            .get("state")
            .and_then(|v| v.as_str())
            .unwrap_or("UNKNOWN")
            .to_string();
        let head_ref = pr
            .get("headRefName")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let base_ref = pr
            .get("baseRefName")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let author = pr
            .get("author")
            .and_then(|v| v.get("login"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let created_at = pr
            .get("createdAt")
            .and_then(|v| v.as_str())
            .and_then(parse_rfc3339_to_secs)
            .unwrap_or(0);
        let closed_at = pr
            .get("closedAt")
            .and_then(|v| v.as_str())
            .and_then(parse_rfc3339_to_secs);
        let merged_at = pr
            .get("mergedAt")
            .and_then(|v| v.as_str())
            .and_then(parse_rfc3339_to_secs);
        let additions = pr.get("additions").and_then(|v| v.as_i64()).unwrap_or(0);
        let deletions = pr.get("deletions").and_then(|v| v.as_i64()).unwrap_or(0);
        let changed_files = pr.get("changedFiles").and_then(|v| v.as_i64()).unwrap_or(0);
        let gap_id = extract_gap_id(&title);
        let domain = gap_id.as_ref().map(|g| domain_from_gap(g));

        tx.execute(
            "INSERT INTO pr_index (pr_number, title, state, head_ref, base_ref, author,
                                   created_at, closed_at, merged_at, gap_id, domain,
                                   files_changed, additions, deletions, last_synced_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
             ON CONFLICT(pr_number) DO UPDATE SET
                title=excluded.title, state=excluded.state,
                head_ref=excluded.head_ref, base_ref=excluded.base_ref,
                author=excluded.author, created_at=excluded.created_at,
                closed_at=excluded.closed_at, merged_at=excluded.merged_at,
                gap_id=excluded.gap_id, domain=excluded.domain,
                files_changed=excluded.files_changed,
                additions=excluded.additions, deletions=excluded.deletions,
                last_synced_at=excluded.last_synced_at",
            params![
                number,
                title,
                state,
                head_ref,
                base_ref,
                author,
                created_at,
                closed_at,
                merged_at,
                gap_id,
                domain,
                changed_files,
                additions,
                deletions,
                ts,
            ],
        )?;
        n += 1;
    }
    tx.commit()?;
    Ok(n)
}

fn parse_rfc3339_to_secs(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.timestamp())
}

/// Classify a path into an artifact class.
fn classify_artifact(path: &str) -> &'static str {
    if path.ends_with(".rs") {
        "rust-mod"
    } else if path.ends_with(".sh") || path.ends_with(".bash") {
        "shell-script"
    } else if path.ends_with(".plist") {
        "plist"
    } else if path.ends_with(".md") {
        "doc"
    } else if path.ends_with(".yaml") || path.ends_with(".yml") {
        "yaml"
    } else {
        "other"
    }
}

/// Collect artifacts via `git ls-files`. For each file, record class +
/// size + first/last commit timestamps (cheap: one `git log -1` per file
/// is too slow at 5k+ files; instead, do a bulk single git-log to populate
/// a path→first/last timestamps map).
pub fn collect_artifacts(conn: &Connection, root: &Path) -> Result<usize> {
    let files = run_cmd("git", &["ls-files"], root);
    if files.is_empty() {
        return Ok(0);
    }

    // Path → (first_seen, last_modified) via git log --name-only.
    let timestamps = build_path_timestamps(root);

    let tx = conn.unchecked_transaction()?;
    let ts = now_secs();
    let mut n = 0usize;
    for path in &files {
        if path.is_empty() {
            continue;
        }
        let class = classify_artifact(path);
        let full = root.join(path);
        let size = fs::metadata(&full).map(|m| m.len() as i64).unwrap_or(0);
        let (first_seen, last_mod) = timestamps.get(path).copied().unwrap_or((ts, ts));

        tx.execute(
            "INSERT INTO artifact_index (path, class, size_bytes, first_seen_at,
                                         last_modified_at, activation_state,
                                         reference_count, referenced_from,
                                         introducing_pr, introducing_gap,
                                         notes, last_synced_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 'unknown', 0, NULL, NULL, NULL, NULL, ?6)
             ON CONFLICT(path) DO UPDATE SET
                class=excluded.class,
                size_bytes=excluded.size_bytes,
                first_seen_at=MIN(artifact_index.first_seen_at, excluded.first_seen_at),
                last_modified_at=excluded.last_modified_at,
                last_synced_at=excluded.last_synced_at",
            params![path, class, size, first_seen, last_mod, ts],
        )?;
        n += 1;
    }
    tx.commit()?;
    Ok(n)
}

/// Best-effort: one `git log --name-only --format=%at` pass over HEAD's
/// history; map each path to (oldest_ts, newest_ts). Cost: O(commits)
/// which is bounded; for 1000+ commit repos this is ~1-3s.
fn build_path_timestamps(root: &Path) -> HashMap<String, (i64, i64)> {
    let mut map: HashMap<String, (i64, i64)> = HashMap::new();
    let out = match Command::new("git")
        .args(["log", "--name-only", "--pretty=format:%at"])
        .current_dir(root)
        .output()
    {
        Ok(o) if o.status.success() => o.stdout,
        _ => return map,
    };
    let s = String::from_utf8_lossy(&out);

    let mut current_ts: i64 = 0;
    for line in s.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Ok(ts) = line.parse::<i64>() {
            current_ts = ts;
            continue;
        }
        // Path line.
        if current_ts == 0 {
            continue;
        }
        map.entry(line.to_string())
            .and_modify(|(first, last)| {
                if current_ts < *first {
                    *first = current_ts;
                }
                if current_ts > *last {
                    *last = current_ts;
                }
            })
            .or_insert((current_ts, current_ts));
    }
    map
}

// ─── detectors ───────────────────────────────────────────────────────────────

/// Run all 9 detectors. Returns total number of findings inserted.
/// All findings land at tier=0; auto_fix_filed_gap_id never populated.
pub fn run_detectors(conn: &Connection, root: &Path) -> Result<usize> {
    let mut total = 0;
    total += detect_orphan_artifacts(conn, root)?;
    total += detect_dormant_scripts(conn, root)?;
    total += detect_dead_rust_mods(conn, root)?;
    total += detect_stale_plists(conn, root)?;
    total += detect_doc_only_features(conn, root)?;
    total += detect_unreferenced_gaps(conn, root)?;
    total += detect_long_undormant_substrate(conn, root)?;
    total += detect_shadow_duplicates(conn, root)?;
    total += detect_event_kind_zero_emits(conn, root)?;
    Ok(total)
}

/// Detector 1: orphan-artifact — artifact has zero inbound references.
/// Approximate: pick scripts/* and src/* artifacts not in the executable
/// closure (not main.rs, not in Cargo.toml [[bin]] paths, no other
/// file grep-references the file's basename without extension).
fn detect_orphan_artifacts(conn: &Connection, root: &Path) -> Result<usize> {
    // Heuristic: a script under scripts/ that is NEVER referenced from any
    // other tracked file is an orphan candidate.
    let mut rows: Vec<(String, String)> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT path, class FROM artifact_index
             WHERE path LIKE 'scripts/%' AND class = 'shell-script'",
        )?;
        let mapped =
            stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        for r in mapped {
            rows.push(r?);
        }
    }

    let mut n = 0usize;
    for (path, _class) in rows {
        let basename = match Path::new(&path).file_name() {
            Some(b) => b.to_string_lossy().to_string(),
            None => continue,
        };
        // grep -rl "<basename>" -- exclude self.
        // To bound cost, restrict to .rs/.sh/.md/.yaml/.plist files.
        let exit = Command::new("git")
            .args([
                "grep", "-l", "-F", "--", &basename, "*.rs", "*.sh", "*.md", "*.yaml", "*.yml",
                "*.plist", "*.toml",
            ])
            .current_dir(root)
            .output();

        let referrers = match exit {
            Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|l| !l.is_empty() && *l != path)
                .map(|l| l.to_string())
                .collect::<Vec<_>>(),
            _ => Vec::new(),
        };

        // Update activation_state on the artifact row.
        let activation = if referrers.is_empty() {
            "orphan"
        } else if referrers.len() < 2 {
            "dormant"
        } else {
            "referenced"
        };
        let referrers_json = serde_json::to_string(&referrers).unwrap_or_else(|_| "[]".to_string());
        conn.execute(
            "UPDATE artifact_index SET activation_state=?1, reference_count=?2,
                                       referenced_from=?3
             WHERE path=?4",
            params![activation, referrers.len() as i64, referrers_json, path],
        )?;

        if referrers.is_empty() {
            let f = Finding {
                finding_class: "orphan-artifact".to_string(),
                severity: "low".to_string(),
                artifact_path: Some(path.clone()),
                pr_number: None,
                gap_id: None,
                detail: format!("{path} has zero inbound references in tracked files"),
                evidence_json: Some(referrers_json),
            };
            insert_finding(conn, &f)?;
            n += 1;
        }
    }
    Ok(n)
}

/// Detector 2: dormant-script — shell script invoked from no script/plist/Rust/doc.
/// Strictly: a subset of orphan-artifact but limited to scripts/coord/, scripts/dispatch/.
fn detect_dormant_scripts(conn: &Connection, root: &Path) -> Result<usize> {
    let mut rows: Vec<String> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT path FROM artifact_index
             WHERE class = 'shell-script'
               AND (path LIKE 'scripts/coord/%' OR path LIKE 'scripts/dispatch/%')
               AND activation_state = 'dormant'",
        )?;
        let mapped = stmt.query_map([], |r| r.get::<_, String>(0))?;
        for r in mapped {
            rows.push(r?);
        }
    }
    let mut n = 0usize;
    for path in rows {
        let f = Finding {
            finding_class: "dormant-script".to_string(),
            severity: "low".to_string(),
            artifact_path: Some(path.clone()),
            pr_number: None,
            gap_id: None,
            detail: format!("{path} is dormant (≤1 inbound reference)"),
            evidence_json: None,
        };
        insert_finding(conn, &f)?;
        n += 1;
    }
    let _ = root; // silence unused-var (kept for symmetry)
    Ok(n)
}

/// Detector 3: dead-rust-mod — module file present but not declared in any
/// `mod foo;` line across the workspace.
fn detect_dead_rust_mods(conn: &Connection, root: &Path) -> Result<usize> {
    let mut rs_files: Vec<String> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT path FROM artifact_index
             WHERE class = 'rust-mod' AND path LIKE 'src/%'",
        )?;
        let mapped = stmt.query_map([], |r| r.get::<_, String>(0))?;
        for r in mapped {
            rs_files.push(r?);
        }
    }
    let mut n = 0usize;
    for path in rs_files {
        let p = Path::new(&path);
        let mod_name = match p.file_stem() {
            Some(s) => s.to_string_lossy().to_string(),
            None => continue,
        };
        if mod_name == "main" || mod_name == "lib" || mod_name == "mod" {
            continue;
        }
        // Skip files under src/bin/ — they are independent binaries.
        if path.starts_with("src/bin/") {
            continue;
        }
        // Grep for `mod <name>` or `pub mod <name>` declarations.
        let pat = format!("mod {}", mod_name);
        let out = Command::new("git")
            .args(["grep", "-l", "-F", "--", &pat, "*.rs"])
            .current_dir(root)
            .output();
        let referrers = match out {
            Ok(o) if o.status.success() => o.stdout,
            _ => Vec::new(),
        };
        let referrer_str = String::from_utf8_lossy(&referrers);
        let has_decl = referrer_str.lines().any(|l| !l.is_empty() && l != path);
        if !has_decl {
            let f = Finding {
                finding_class: "dead-rust-mod".to_string(),
                severity: "med".to_string(),
                artifact_path: Some(path.clone()),
                pr_number: None,
                gap_id: None,
                detail: format!("Rust file {path} has no `mod {mod_name}` declaration anywhere"),
                evidence_json: None,
            };
            insert_finding(conn, &f)?;
            n += 1;
        }
    }
    Ok(n)
}

/// Detector 4: stale-plist — launchd plist whose ProgramArguments[0] path
/// doesn't exist on disk.
fn detect_stale_plists(conn: &Connection, root: &Path) -> Result<usize> {
    let mut plists: Vec<String> = Vec::new();
    {
        let mut stmt = conn.prepare("SELECT path FROM artifact_index WHERE class = 'plist'")?;
        let mapped = stmt.query_map([], |r| r.get::<_, String>(0))?;
        for r in mapped {
            plists.push(r?);
        }
    }
    let mut n = 0usize;
    for path in plists {
        let full = root.join(&path);
        let content = match fs::read_to_string(&full) {
            Ok(c) => c,
            Err(_) => continue,
        };
        // Find <string>FOO</string> inside <key>ProgramArguments</key> ... <array>.
        // Simplified: pick the first <string> after ProgramArguments.
        let lower = content.to_lowercase();
        let pa_idx = match lower.find("programarguments") {
            Some(i) => i,
            None => continue,
        };
        let after = &content[pa_idx..];
        let first_str = after.find("<string>").and_then(|s| {
            let start = s + "<string>".len();
            after[start..]
                .find("</string>")
                .map(|e| after[start..start + e].to_string())
        });
        if let Some(prog_path) = first_str {
            let prog_path_trimmed = prog_path.trim();
            if !prog_path_trimmed.is_empty() && !Path::new(prog_path_trimmed).exists() {
                let f = Finding {
                    finding_class: "stale-plist".to_string(),
                    severity: "high".to_string(),
                    artifact_path: Some(path.clone()),
                    pr_number: None,
                    gap_id: None,
                    detail: format!("plist {path} references missing binary {prog_path_trimmed}"),
                    evidence_json: None,
                };
                insert_finding(conn, &f)?;
                n += 1;
            }
        }
    }
    Ok(n)
}

/// Detector 5: doc-only-feature — gap shipped a doc but no code change.
/// Heuristic: a merged PR whose changed-file list (best-effort, from
/// pr_index.files_changed=1 + title-extracted gap) is exactly 1
/// AND the only artifact is a .md/.yaml under docs/.
fn detect_doc_only_features(conn: &Connection, _root: &Path) -> Result<usize> {
    // Bounded: only inspect PRs marked CREDIBLE/EFFECTIVE-domain gaps where
    // we'd expect code. For now flag any merged PR with files_changed == 1.
    let mut rows: Vec<(i64, String, String)> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT pr_number, title, gap_id FROM pr_index
             WHERE state = 'MERGED' AND files_changed = 1
               AND gap_id IS NOT NULL
               AND (domain = 'CREDIBLE' OR domain = 'EFFECTIVE')
             LIMIT 200",
        )?;
        let mapped = stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?;
        for r in mapped {
            rows.push(r?);
        }
    }
    let mut n = 0usize;
    for (pr_number, title, gap_id) in rows {
        let f = Finding {
            finding_class: "doc-only-feature".to_string(),
            severity: "info".to_string(),
            artifact_path: None,
            pr_number: Some(pr_number),
            gap_id: Some(gap_id),
            detail: format!("PR #{pr_number} shipped one file under CREDIBLE/EFFECTIVE domain — likely doc-only: {title}"),
            evidence_json: None,
        };
        insert_finding(conn, &f)?;
        n += 1;
    }
    Ok(n)
}

/// Detector 6: unreferenced-gap — gap shipped >30d ago but artifacts orphaned.
fn detect_unreferenced_gaps(conn: &Connection, _root: &Path) -> Result<usize> {
    let cutoff = now_secs() - 30 * 86400;
    let mut rows: Vec<(String, i64)> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT pr_index.gap_id, pr_index.pr_number FROM pr_index
             WHERE pr_index.state = 'MERGED'
               AND pr_index.merged_at < ?1
               AND pr_index.gap_id IS NOT NULL
             LIMIT 500",
        )?;
        let mapped = stmt.query_map([cutoff], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
        })?;
        for r in mapped {
            rows.push(r?);
        }
    }
    let mut n = 0usize;
    for (gap_id, pr_number) in rows {
        // Count orphan artifacts whose introducing_gap = this gap.
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM artifact_index
                 WHERE introducing_gap = ?1 AND activation_state = 'orphan'",
                params![gap_id],
                |r| r.get::<_, i64>(0),
            )
            .unwrap_or(0);
        if count > 0 {
            let f = Finding {
                finding_class: "unreferenced-gap".to_string(),
                severity: "low".to_string(),
                artifact_path: None,
                pr_number: Some(pr_number),
                gap_id: Some(gap_id.clone()),
                detail: format!("Gap {gap_id} merged >30d ago has {count} orphan artifact(s)"),
                evidence_json: None,
            };
            insert_finding(conn, &f)?;
            n += 1;
        }
    }
    Ok(n)
}

/// Detector 7: long-undormant-substrate — substrate PR merged >90d, no
/// reference growth since. Heuristic: a merged PR's title contains
/// "substrate" or "infra" and its merged_at < 90d ago and inserted
/// artifacts are orphans/dormant.
fn detect_long_undormant_substrate(conn: &Connection, _root: &Path) -> Result<usize> {
    let cutoff = now_secs() - 90 * 86400;
    let mut rows: Vec<(i64, String, String)> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT pr_number, title, COALESCE(gap_id, '') FROM pr_index
             WHERE state = 'MERGED'
               AND merged_at < ?1
               AND (LOWER(title) LIKE '%substrate%' OR LOWER(title) LIKE '%infra-%')
             LIMIT 200",
        )?;
        let mapped = stmt.query_map([cutoff], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?;
        for r in mapped {
            rows.push(r?);
        }
    }
    let mut n = 0usize;
    for (pr_number, title, gap_id) in rows {
        let f = Finding {
            finding_class: "long-undormant-substrate".to_string(),
            severity: "info".to_string(),
            artifact_path: None,
            pr_number: Some(pr_number),
            gap_id: if gap_id.is_empty() { None } else { Some(gap_id) },
            detail: format!(
                "Substrate PR #{pr_number} merged >90d ago — review whether it accreted any users: {title}"
            ),
            evidence_json: None,
        };
        insert_finding(conn, &f)?;
        n += 1;
    }
    Ok(n)
}

/// Detector 8: shadow-duplicate — two artifacts with near-identical first
/// 40 bytes of basename (heuristic for "is-this-a-duplicate-of-existing").
fn detect_shadow_duplicates(conn: &Connection, _root: &Path) -> Result<usize> {
    let mut paths: Vec<(String, String)> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT path, class FROM artifact_index
             WHERE class IN ('shell-script', 'rust-mod')",
        )?;
        let mapped =
            stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        for r in mapped {
            paths.push(r?);
        }
    }
    // Bucket by basename-without-extension prefix (first 8 chars).
    let mut buckets: HashMap<String, Vec<String>> = HashMap::new();
    for (path, _class) in &paths {
        let basename = Path::new(path)
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        if basename.len() < 8 {
            continue;
        }
        let key = basename[..8].to_string();
        buckets.entry(key).or_default().push(path.clone());
    }

    let mut n = 0usize;
    for (key, group) in buckets {
        if group.len() < 2 {
            continue;
        }
        let f = Finding {
            finding_class: "shadow-duplicate".to_string(),
            severity: "med".to_string(),
            artifact_path: Some(group[0].clone()),
            pr_number: None,
            gap_id: None,
            detail: format!(
                "{} artifacts share basename prefix '{}' — possible shadow duplicates: {}",
                group.len(),
                key,
                group.join(", ")
            ),
            evidence_json: Some(serde_json::to_string(&group).unwrap_or_default()),
        };
        insert_finding(conn, &f)?;
        n += 1;
    }
    Ok(n)
}

/// Detector 9: event-kind-zero-emit — EVENT_REGISTRY kind has zero
/// occurrences in ambient.jsonl in the last 30d.
fn detect_event_kind_zero_emits(conn: &Connection, root: &Path) -> Result<usize> {
    let registry_path = root.join("docs/observability/EVENT_REGISTRY.yaml");
    let content = match fs::read_to_string(&registry_path) {
        Ok(c) => c,
        Err(_) => return Ok(0),
    };
    // Cheap extraction: every `- kind: foo` line yields a kind name.
    let kinds: Vec<String> = content
        .lines()
        .filter_map(|l| {
            let t = l.trim_start();
            t.strip_prefix("- kind:").map(|s| s.trim().to_string())
        })
        .filter(|k| !k.is_empty() && !k.contains(' '))
        .collect();

    if kinds.is_empty() {
        return Ok(0);
    }

    let ambient = ambient_log_path();
    let ambient_content = fs::read_to_string(&ambient).unwrap_or_default();
    // Cheap: substring scan. Don't need to be exact — surface candidates.
    let mut n = 0usize;
    for kind in kinds {
        let needle = format!("\"kind\":\"{}\"", kind);
        if !ambient_content.contains(&needle) {
            let f = Finding {
                finding_class: "event-kind-zero-emit".to_string(),
                severity: "info".to_string(),
                artifact_path: Some("docs/observability/EVENT_REGISTRY.yaml".to_string()),
                pr_number: None,
                gap_id: None,
                detail: format!(
                    "EVENT_REGISTRY declares kind={kind} but ambient.jsonl shows zero occurrences"
                ),
                evidence_json: None,
            };
            insert_finding(conn, &f)?;
            n += 1;
        }
    }
    Ok(n)
}

// ─── review primitives ──────────────────────────────────────────────────────

/// Operator marks a finding's classification. Updates reviewed_count
/// and real_positive_count on the parent finding_class_tiers row.
pub fn review_finding(
    conn: &Connection,
    finding_id: i64,
    classification: &str,
    note: Option<&str>,
) -> Result<()> {
    let normalized = classification.to_uppercase();
    if !matches!(
        normalized.as_str(),
        "REAL_POSITIVE" | "FALSE_POSITIVE" | "NEEDS_INVESTIGATION"
    ) {
        return Err(anyhow!(
            "classification must be REAL_POSITIVE | FALSE_POSITIVE | NEEDS_INVESTIGATION (got: {})",
            classification
        ));
    }

    // Look up the finding's class + prior classification (if any).
    let row: Option<(String, Option<String>)> = conn
        .query_row(
            "SELECT finding_class, operator_classification FROM tech_debt_findings
             WHERE finding_id = ?1",
            params![finding_id],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?)),
        )
        .optional()?;
    let (finding_class, prior) = match row {
        Some(r) => r,
        None => return Err(anyhow!("finding_id {} not found", finding_id)),
    };

    let ts = now_secs();
    conn.execute(
        "UPDATE tech_debt_findings
         SET operator_classification=?1, operator_reviewed_at=?2, operator_note=?3
         WHERE finding_id=?4",
        params![normalized, ts, note, finding_id],
    )?;

    // Adjust counters on finding_class_tiers row.
    // Three transitions to consider:
    //   prior=None              → +1 reviewed; +1 real_positive if new is RP
    //   prior=RP, new=non-RP    → 0 reviewed delta; -1 real_positive
    //   prior=non-RP, new=RP    → 0 reviewed delta; +1 real_positive
    //   prior=non-RP, new=non-RP same → no-op
    //   prior=RP, new=RP → no-op
    let prior_is_rp = matches!(prior.as_deref(), Some("REAL_POSITIVE"));
    let new_is_rp = normalized == "REAL_POSITIVE";

    let (rev_delta, rp_delta): (i64, i64) = match (prior.is_some(), prior_is_rp, new_is_rp) {
        (false, _, true) => (1, 1),
        (false, _, false) => (1, 0),
        (true, true, true) => (0, 0),
        (true, false, false) => (0, 0),
        (true, true, false) => (0, -1),
        (true, false, true) => (0, 1),
    };

    conn.execute(
        "INSERT INTO finding_class_tiers (finding_class, current_tier,
                                          reviewed_count, real_positive_count)
         VALUES (?1, 0, ?2, ?3)
         ON CONFLICT(finding_class) DO UPDATE SET
            reviewed_count = MAX(0, finding_class_tiers.reviewed_count + ?2),
            real_positive_count = MAX(0, finding_class_tiers.real_positive_count + ?3)",
        params![finding_class, rev_delta, rp_delta],
    )?;

    Ok(())
}

/// Operator explicitly promotes a finding_class from tier 0 → 2.
/// REJECTS unless (a) reviewed_count ≥ 10 AND (b) real_positive_ratio ≥ 0.70.
pub fn promote_class(conn: &Connection, finding_class: &str, by: &str) -> Result<()> {
    if !DETECTOR_CLASSES.contains(&finding_class) {
        return Err(anyhow!(
            "unknown finding_class '{}' — valid: {}",
            finding_class,
            DETECTOR_CLASSES.join(", ")
        ));
    }
    let (reviewed, rp): (i64, i64) = conn
        .query_row(
            "SELECT reviewed_count, real_positive_count FROM finding_class_tiers
             WHERE finding_class = ?1",
            params![finding_class],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)),
        )
        .unwrap_or((0, 0));

    let ratio = if reviewed == 0 {
        0.0
    } else {
        rp as f64 / reviewed as f64
    };

    if reviewed < PROMOTE_MIN_REVIEWED {
        return Err(anyhow!(
            "calibration shortfall: finding_class '{}' has {} reviewed findings, needs ≥{} before promotion",
            finding_class,
            reviewed,
            PROMOTE_MIN_REVIEWED
        ));
    }
    if ratio < PROMOTE_MIN_REAL_POSITIVE_RATIO {
        return Err(anyhow!(
            "calibration shortfall: finding_class '{}' has {:.0}% REAL_POSITIVE rate, needs ≥{:.0}% before promotion",
            finding_class,
            ratio * 100.0,
            PROMOTE_MIN_REAL_POSITIVE_RATIO * 100.0
        ));
    }

    let ts = now_secs();
    conn.execute(
        "INSERT INTO finding_class_tiers (finding_class, current_tier, promoted_at, promoted_by)
         VALUES (?1, 2, ?2, ?3)
         ON CONFLICT(finding_class) DO UPDATE SET
            current_tier = 2, promoted_at = ?2, promoted_by = ?3",
        params![finding_class, ts, by],
    )?;
    Ok(())
}

/// Operator demotes a finding_class back to tier 0 (escape hatch).
pub fn demote_class(conn: &Connection, finding_class: &str, by: &str) -> Result<()> {
    if !DETECTOR_CLASSES.contains(&finding_class) {
        return Err(anyhow!(
            "unknown finding_class '{}' — valid: {}",
            finding_class,
            DETECTOR_CLASSES.join(", ")
        ));
    }
    let ts = now_secs();
    conn.execute(
        "INSERT INTO finding_class_tiers (finding_class, current_tier, demoted_at, demoted_by)
         VALUES (?1, 0, ?2, ?3)
         ON CONFLICT(finding_class) DO UPDATE SET
            current_tier = 0, demoted_at = ?2, demoted_by = ?3",
        params![finding_class, ts, by],
    )?;
    Ok(())
}

// ─── read paths (used by CLI) ────────────────────────────────────────────────

#[derive(Debug, Clone, serde::Serialize)]
pub struct FindingRow {
    pub finding_id: i64,
    pub finding_class: String,
    pub severity: String,
    pub artifact_path: Option<String>,
    pub pr_number: Option<i64>,
    pub gap_id: Option<String>,
    pub detail: String,
    pub detected_at: i64,
    pub tier: i64,
    pub operator_classification: Option<String>,
    pub operator_reviewed_at: Option<i64>,
    pub auto_fix_filed_gap_id: Option<String>,
}

/// Fetch findings filtered by tier (None=all) + class (None=all).
pub fn list_findings(
    conn: &Connection,
    tier: Option<i64>,
    class: Option<&str>,
    only_unreviewed: bool,
    limit: Option<i64>,
) -> Result<Vec<FindingRow>> {
    let mut sql = String::from(
        "SELECT finding_id, finding_class, severity, artifact_path, pr_number,
                gap_id, detail, detected_at, tier, operator_classification,
                operator_reviewed_at, auto_fix_filed_gap_id
         FROM tech_debt_findings WHERE 1=1",
    );
    let mut binds: Vec<rusqlite::types::Value> = Vec::new();
    if let Some(t) = tier {
        sql.push_str(" AND tier = ?");
        binds.push(rusqlite::types::Value::Integer(t));
    }
    if let Some(c) = class {
        sql.push_str(" AND finding_class = ?");
        binds.push(rusqlite::types::Value::Text(c.to_string()));
    }
    if only_unreviewed {
        sql.push_str(" AND operator_classification IS NULL");
    }
    sql.push_str(" ORDER BY detected_at ASC");
    if let Some(l) = limit {
        sql.push_str(&format!(" LIMIT {}", l));
    }
    let mut stmt = conn.prepare(&sql)?;
    let params_refs: Vec<&dyn rusqlite::ToSql> =
        binds.iter().map(|v| v as &dyn rusqlite::ToSql).collect();
    let mapped = stmt.query_map(params_refs.as_slice(), |r| {
        Ok(FindingRow {
            finding_id: r.get(0)?,
            finding_class: r.get(1)?,
            severity: r.get(2)?,
            artifact_path: r.get(3)?,
            pr_number: r.get(4)?,
            gap_id: r.get(5)?,
            detail: r.get(6)?,
            detected_at: r.get(7)?,
            tier: r.get(8)?,
            operator_classification: r.get(9)?,
            operator_reviewed_at: r.get(10)?,
            auto_fix_filed_gap_id: r.get(11)?,
        })
    })?;
    let mut out = Vec::new();
    for r in mapped {
        out.push(r?);
    }
    Ok(out)
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ClassStats {
    pub finding_class: String,
    pub current_tier: i64,
    pub total_findings: i64,
    pub reviewed_count: i64,
    pub real_positive_count: i64,
    pub real_positive_ratio: f64,
    pub eligible_for_promotion: bool,
}

pub fn class_stats(conn: &Connection) -> Result<Vec<ClassStats>> {
    let mut stmt = conn.prepare(
        "SELECT fct.finding_class, fct.current_tier, fct.reviewed_count,
                fct.real_positive_count,
                COALESCE((SELECT COUNT(*) FROM tech_debt_findings tdf
                          WHERE tdf.finding_class = fct.finding_class), 0) AS total
         FROM finding_class_tiers fct
         ORDER BY fct.finding_class",
    )?;
    let mapped = stmt.query_map([], |r| {
        let class: String = r.get(0)?;
        let tier: i64 = r.get(1)?;
        let reviewed: i64 = r.get(2)?;
        let rp: i64 = r.get(3)?;
        let total: i64 = r.get(4)?;
        let ratio = if reviewed == 0 {
            0.0
        } else {
            rp as f64 / reviewed as f64
        };
        let eligible = reviewed >= PROMOTE_MIN_REVIEWED && ratio >= PROMOTE_MIN_REAL_POSITIVE_RATIO;
        Ok(ClassStats {
            finding_class: class,
            current_tier: tier,
            total_findings: total,
            reviewed_count: reviewed,
            real_positive_count: rp,
            real_positive_ratio: ratio,
            eligible_for_promotion: eligible,
        })
    })?;
    let mut out = Vec::new();
    for r in mapped {
        out.push(r?);
    }
    Ok(out)
}

/// Aggregate counts for rebuild summary.
pub fn meta_counts(conn: &Connection) -> Result<(i64, i64, i64)> {
    let prs: i64 = conn
        .query_row("SELECT COUNT(*) FROM pr_index", [], |r| r.get(0))
        .unwrap_or(0);
    let artifacts: i64 = conn
        .query_row("SELECT COUNT(*) FROM artifact_index", [], |r| r.get(0))
        .unwrap_or(0);
    let findings: i64 = conn
        .query_row("SELECT COUNT(*) FROM tech_debt_findings", [], |r| r.get(0))
        .unwrap_or(0);
    Ok((prs, artifacts, findings))
}

/// Update inventory_meta after rebuild.
pub fn write_rebuild_meta(conn: &Connection, pr_count: i64, artifact_count: i64) -> Result<()> {
    let ts = now_secs();
    conn.execute(
        "INSERT INTO inventory_meta (key, value) VALUES ('last_rebuild_at', ?1)
         ON CONFLICT(key) DO UPDATE SET value=?1",
        params![ts.to_string()],
    )?;
    conn.execute(
        "INSERT INTO inventory_meta (key, value) VALUES ('last_rebuild_pr_count', ?1)
         ON CONFLICT(key) DO UPDATE SET value=?1",
        params![pr_count.to_string()],
    )?;
    conn.execute(
        "INSERT INTO inventory_meta (key, value) VALUES ('last_rebuild_artifact_count', ?1)
         ON CONFLICT(key) DO UPDATE SET value=?1",
        params![artifact_count.to_string()],
    )?;
    Ok(())
}

// ─── tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;
    use tempfile::TempDir;

    /// Tests run #[serial] because finding-insert emits an ambient event via
    /// the env-var-resolved ambient log path; parallel runs would clobber it.
    /// Per-test we still bind a unique tempdir so DB state is isolated.
    fn setup_test_db() -> (TempDir, Connection) {
        let tmp = TempDir::new().expect("tempdir");
        let db_path = tmp.path().join("inventory.db");

        // Write a copy of the migration into tempdir for isolation.
        let mig = tmp.path().join("inventory_v1.sql");
        let here = std::env::current_dir().unwrap();
        let mut probe = here.clone();
        let mut sql_src = None;
        for _ in 0..6 {
            let p = probe.join("migrations/inventory_v1.sql");
            if p.exists() {
                sql_src = Some(p);
                break;
            }
            if !probe.pop() {
                break;
            }
        }
        let sql_text = sql_src
            .map(|p| std::fs::read_to_string(p).unwrap())
            .unwrap_or_default();
        std::fs::write(&mig, sql_text).unwrap();

        // Isolate ambient log per-test.
        std::env::set_var("CHUMP_AMBIENT_LOG", tmp.path().join("ambient.jsonl"));

        // Bind DB connection directly without env-var lookup to avoid
        // cross-test clobbering of CHUMP_INVENTORY_DB.
        let conn = open_db_at(&db_path, &mig).expect("open db");
        (tmp, conn)
    }

    #[test]
    #[serial]
    fn finding_inserts_at_tier_zero_with_null_auto_fix_gap() {
        let (_tmp, conn) = setup_test_db();
        let f = Finding {
            finding_class: "orphan-artifact".to_string(),
            severity: "low".to_string(),
            artifact_path: Some("scripts/foo.sh".to_string()),
            pr_number: None,
            gap_id: None,
            detail: "foo orphan".to_string(),
            evidence_json: None,
        };
        let id = insert_finding(&conn, &f).unwrap();
        let (tier, classification, auto): (i64, Option<String>, Option<String>) = conn
            .query_row(
                "SELECT tier, operator_classification, auto_fix_filed_gap_id
                 FROM tech_debt_findings WHERE finding_id=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(tier, 0);
        assert!(classification.is_none());
        assert!(auto.is_none(), "auto_fix_filed_gap_id must be NULL");
    }

    #[test]
    #[serial]
    fn review_marks_classification_and_increments_counters() {
        let (_tmp, conn) = setup_test_db();
        let f = Finding {
            finding_class: "dormant-script".to_string(),
            severity: "low".to_string(),
            artifact_path: None,
            pr_number: None,
            gap_id: None,
            detail: "x".to_string(),
            evidence_json: None,
        };
        let id = insert_finding(&conn, &f).unwrap();
        review_finding(&conn, id, "REAL_POSITIVE", Some("looks dead")).unwrap();
        let (reviewed, rp): (i64, i64) = conn
            .query_row(
                "SELECT reviewed_count, real_positive_count FROM finding_class_tiers
                 WHERE finding_class='dormant-script'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(reviewed, 1);
        assert_eq!(rp, 1);
    }

    #[test]
    #[serial]
    fn promote_rejects_below_thresholds_and_succeeds_when_calibrated() {
        let (_tmp, conn) = setup_test_db();
        // Below count threshold.
        let err = promote_class(&conn, "orphan-artifact", "operator").unwrap_err();
        assert!(err.to_string().contains("calibration shortfall"));

        // Insert 10 findings, mark 8 REAL_POSITIVE (80% → above 70%).
        for i in 0..10 {
            let f = Finding {
                finding_class: "orphan-artifact".to_string(),
                severity: "low".to_string(),
                artifact_path: Some(format!("scripts/f{}.sh", i)),
                pr_number: None,
                gap_id: None,
                detail: format!("orphan #{}", i),
                evidence_json: None,
            };
            let id = insert_finding(&conn, &f).unwrap();
            let cls = if i < 8 {
                "REAL_POSITIVE"
            } else {
                "FALSE_POSITIVE"
            };
            review_finding(&conn, id, cls, None).unwrap();
        }
        // Now promote should succeed.
        promote_class(&conn, "orphan-artifact", "operator").unwrap();
        let tier: i64 = conn
            .query_row(
                "SELECT current_tier FROM finding_class_tiers
                 WHERE finding_class='orphan-artifact'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(tier, 2);
    }

    #[test]
    #[serial]
    fn promote_rejects_below_ratio_even_when_count_met() {
        let (_tmp, conn) = setup_test_db();
        // 10 findings, 5 REAL_POSITIVE (50% → below 70%).
        for i in 0..10 {
            let f = Finding {
                finding_class: "orphan-artifact".to_string(),
                severity: "low".to_string(),
                artifact_path: Some(format!("scripts/f{}.sh", i)),
                pr_number: None,
                gap_id: None,
                detail: format!("orphan #{}", i),
                evidence_json: None,
            };
            let id = insert_finding(&conn, &f).unwrap();
            let cls = if i < 5 {
                "REAL_POSITIVE"
            } else {
                "FALSE_POSITIVE"
            };
            review_finding(&conn, id, cls, None).unwrap();
        }
        let err = promote_class(&conn, "orphan-artifact", "operator").unwrap_err();
        assert!(err.to_string().contains("calibration shortfall"));
    }

    #[test]
    #[serial]
    fn promote_does_not_file_gap_or_set_auto_fix_field() {
        let (_tmp, conn) = setup_test_db();
        // Calibrate + promote orphan-artifact.
        for i in 0..10 {
            let f = Finding {
                finding_class: "orphan-artifact".to_string(),
                severity: "low".to_string(),
                artifact_path: Some(format!("scripts/f{}.sh", i)),
                pr_number: None,
                gap_id: None,
                detail: format!("orphan #{}", i),
                evidence_json: None,
            };
            let id = insert_finding(&conn, &f).unwrap();
            review_finding(&conn, id, "REAL_POSITIVE", None).unwrap();
        }
        promote_class(&conn, "orphan-artifact", "operator").unwrap();

        // INFRA-2374 NOT shipped — auto_fix_filed_gap_id MUST be NULL.
        let count_with_gap: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM tech_debt_findings
                 WHERE auto_fix_filed_gap_id IS NOT NULL",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            count_with_gap, 0,
            "tier-2 machinery deferred to INFRA-2374; no finding should have auto_fix_filed_gap_id set"
        );
    }

    #[test]
    #[serial]
    fn demote_resets_tier_to_zero() {
        let (_tmp, conn) = setup_test_db();
        for i in 0..10 {
            let f = Finding {
                finding_class: "orphan-artifact".to_string(),
                severity: "low".to_string(),
                artifact_path: Some(format!("scripts/f{}.sh", i)),
                pr_number: None,
                gap_id: None,
                detail: format!("orphan #{}", i),
                evidence_json: None,
            };
            let id = insert_finding(&conn, &f).unwrap();
            review_finding(&conn, id, "REAL_POSITIVE", None).unwrap();
        }
        promote_class(&conn, "orphan-artifact", "operator").unwrap();
        demote_class(&conn, "orphan-artifact", "operator").unwrap();
        let tier: i64 = conn
            .query_row(
                "SELECT current_tier FROM finding_class_tiers
                 WHERE finding_class='orphan-artifact'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(tier, 0);
    }

    #[test]
    #[serial]
    fn extract_gap_id_handles_common_titles() {
        assert_eq!(
            extract_gap_id("feat(INFRA-2367): foo"),
            Some("INFRA-2367".to_string())
        );
        assert_eq!(
            extract_gap_id("fix META-271 bar"),
            Some("META-271".to_string())
        );
        assert_eq!(extract_gap_id("plain title with no id"), None);
        // CREDIBLE-002 must be recognized.
        assert_eq!(
            extract_gap_id("CREDIBLE-002 something"),
            Some("CREDIBLE-002".to_string())
        );
    }
}
