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

// ─── auth resolution (INFRA-2368) ────────────────────────────────────────────

/// Where the GitHub auth token came from. Surfaced to the CLI so the
/// operator can tell why PR collection succeeded or was skipped — the
/// silent-skip behavior on the META-271 first launchd run (pr_index 0/2934)
/// is the regression this enum guards against.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthSource {
    /// $GH_TOKEN was set + non-empty.
    EnvGhToken,
    /// $GITHUB_TOKEN was set + non-empty (some CI runners use this name).
    EnvGithubToken,
    /// `gh auth token` returned a token (keyring / config file).
    GhCliKeyring,
    /// No usable auth path. PR collection will skip.
    Missing,
}

impl AuthSource {
    pub fn label(&self) -> &'static str {
        match self {
            AuthSource::EnvGhToken => "env(GH_TOKEN)",
            AuthSource::EnvGithubToken => "env(GITHUB_TOKEN)",
            AuthSource::GhCliKeyring => "keyring",
            AuthSource::Missing => "missing",
        }
    }
    pub fn is_available(&self) -> bool {
        !matches!(self, AuthSource::Missing)
    }
}

/// Resolve a GitHub auth token via the documented priority chain:
///   1. `$GH_TOKEN` env var (non-empty)
///   2. `$GITHUB_TOKEN` env var (non-empty)
///   3. `gh auth token` (CLI keyring / config)
///   4. Missing — caller skips with a clear warning.
///
/// Returns (token, source). When source is Missing, token is None.
pub fn resolve_gh_auth(root: &Path) -> (Option<String>, AuthSource) {
    if let Ok(t) = std::env::var("GH_TOKEN") {
        let t = t.trim();
        if !t.is_empty() {
            return (Some(t.to_string()), AuthSource::EnvGhToken);
        }
    }
    if let Ok(t) = std::env::var("GITHUB_TOKEN") {
        let t = t.trim();
        if !t.is_empty() {
            return (Some(t.to_string()), AuthSource::EnvGithubToken);
        }
    }
    // Fall back to `gh auth token` — uses the same keyring/config the user
    // already authenticated through. Non-interactive: no prompts.
    let out = Command::new("gh")
        .args(["auth", "token"])
        .current_dir(root)
        .output();
    if let Ok(o) = out {
        if o.status.success() {
            let t = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if !t.is_empty() {
                return (Some(t), AuthSource::GhCliKeyring);
            }
        }
    }
    (None, AuthSource::Missing)
}

/// Resolve `OWNER/REPO` from `git remote get-url origin`. Returns
/// `("repairman29", "chump")` for the chump repo. Falls back to the
/// CHUMP_INVENTORY_REPO env var (form: "owner/repo") for tests.
pub fn resolve_repo_slug(root: &Path) -> Option<(String, String)> {
    if let Ok(slug) = std::env::var("CHUMP_INVENTORY_REPO") {
        let parts: Vec<&str> = slug.split('/').collect();
        if parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty() {
            return Some((parts[0].to_string(), parts[1].to_string()));
        }
    }
    let out = Command::new("git")
        .args(["remote", "get-url", "origin"])
        .current_dir(root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let url = String::from_utf8_lossy(&out.stdout).trim().to_string();
    // Parse https://github.com/<owner>/<repo>.git and git@github.com:<owner>/<repo>.git
    let stripped = url
        .trim_end_matches(".git")
        .trim_end_matches('/')
        .to_string();
    let tail = if let Some(idx) = stripped.find("github.com") {
        let after = &stripped[idx + "github.com".len()..];
        after.trim_start_matches(':').trim_start_matches('/')
    } else {
        return None;
    };
    let parts: Vec<&str> = tail.split('/').collect();
    if parts.len() >= 2 && !parts[0].is_empty() && !parts[1].is_empty() {
        Some((parts[0].to_string(), parts[1].to_string()))
    } else {
        None
    }
}

/// Result of `collect_prs` — surfaces the auth source + index size so the
/// CLI can print "pr_index: N indexed from gh (auth=keyring|env|missing)".
#[derive(Debug, Clone)]
pub struct PrCollectionResult {
    pub indexed: usize,
    pub auth_source: AuthSource,
    pub used_path: PrCollectionPath,
    pub fallback_to_cli: bool,
}

/// Which transport was used: direct REST via curl, or shell-out to `gh pr list`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrCollectionPath {
    /// Used `curl` against the REST API with the resolved token.
    RestCurl,
    /// Used `gh pr list` (CLI path).
    GhCli,
    /// No auth available, did nothing.
    Skipped,
}

/// Collect PRs from GitHub. Auth-resilient (INFRA-2368):
///   * Resolves token via env → keyring → skip-with-warning.
///   * Prefers direct REST via `curl` when an env-var token is present
///     (faster: no `gh` subprocess fork per page).
///   * Falls back to `gh pr list` when only keyring auth is available
///     (avoids leaking the keyring token into a curl command line).
///   * On total failure, returns `PrCollectionPath::Skipped` so callers
///     can disable downstream detectors instead of silently reporting
///     0 findings as if no debt existed.
///
/// Legacy compatibility: this still returns `Result<usize>` via the
/// `indexed` field of `PrCollectionResult`, so the v1 caller signature
/// (`collect_prs(&conn, &root)?`) keeps working via the thin wrapper
/// `collect_prs_legacy`.
pub fn collect_prs_v2(conn: &Connection, root: &Path) -> Result<PrCollectionResult> {
    let (token, auth_source) = resolve_gh_auth(root);

    if token.is_none() {
        eprintln!(
            "[inventory] gh auth missing — set GH_TOKEN, GITHUB_TOKEN, or run `gh auth login` (skipping PR backfill; 3 dependent detectors will be disabled)"
        );
        return Ok(PrCollectionResult {
            indexed: 0,
            auth_source,
            used_path: PrCollectionPath::Skipped,
            fallback_to_cli: false,
        });
    }

    let token = token.expect("checked above");
    let env_token = matches!(
        auth_source,
        AuthSource::EnvGhToken | AuthSource::EnvGithubToken
    );

    let mut fallback_to_cli = false;
    let mut path_used = if env_token {
        PrCollectionPath::RestCurl
    } else {
        PrCollectionPath::GhCli
    };

    // Try REST when we have an env token (cheaper, no fork-per-page).
    let prs_json = if env_token {
        match fetch_prs_via_rest(root, &token) {
            Ok(v) => v,
            Err(e) => {
                eprintln!(
                    "[inventory] REST fetch failed ({e}); falling back to `gh pr list` CLI path"
                );
                fallback_to_cli = true;
                path_used = PrCollectionPath::GhCli;
                fetch_prs_via_gh_cli(root)
            }
        }
    } else {
        fetch_prs_via_gh_cli(root)
    };

    // Index whatever we got.
    let indexed = ingest_prs(conn, &prs_json)?;
    Ok(PrCollectionResult {
        indexed,
        auth_source,
        used_path: path_used,
        fallback_to_cli,
    })
}

/// Backward-compatible wrapper preserving the v1 `collect_prs(...) -> Result<usize>` API.
pub fn collect_prs(conn: &Connection, root: &Path) -> Result<usize> {
    Ok(collect_prs_v2(conn, root)?.indexed)
}

/// REST path: paginate `GET /repos/{owner}/{repo}/pulls?state=all&per_page=100`
/// via `curl`. Returns the concatenated array of PR objects. Bounded:
/// CHUMP_INVENTORY_PR_MAX_PAGES (default 35 — covers ~3500 PRs).
fn fetch_prs_via_rest(root: &Path, token: &str) -> Result<Vec<serde_json::Value>> {
    let (owner, repo) = resolve_repo_slug(root)
        .ok_or_else(|| anyhow!("could not resolve owner/repo from git remote"))?;
    let max_pages: usize = std::env::var("CHUMP_INVENTORY_PR_MAX_PAGES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(35);
    let per_page: usize = std::env::var("CHUMP_INVENTORY_PR_PER_PAGE")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(100);
    let timeout_secs: u64 = std::env::var("CHUMP_INVENTORY_REST_TIMEOUT_S")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(30);

    let mut all: Vec<serde_json::Value> = Vec::new();
    for page in 1..=max_pages {
        let url = format!(
            "https://api.github.com/repos/{owner}/{repo}/pulls?state=all&per_page={per_page}&page={page}&sort=created&direction=desc"
        );
        let out = Command::new("curl")
            .args([
                "-sS",
                "--fail",
                "--max-time",
                &timeout_secs.to_string(),
                "-H",
                &format!("Authorization: Bearer {token}"),
                "-H",
                "Accept: application/vnd.github+json",
                "-H",
                "X-GitHub-Api-Version: 2022-11-28",
                "-H",
                "User-Agent: chump-inventory",
                &url,
            ])
            .current_dir(root)
            .output()
            .with_context(|| format!("invoking curl for REST page {page}"))?;
        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            return Err(anyhow!("curl failed on page {page}: {stderr}"));
        }
        let body = String::from_utf8_lossy(&out.stdout).to_string();
        let parsed: serde_json::Value = serde_json::from_str(&body)
            .with_context(|| format!("parsing REST body for page {page}"))?;
        let arr = match parsed.as_array() {
            Some(a) => a.clone(),
            None => {
                return Err(anyhow!(
                    "REST page {page} body is not an array: {}",
                    body.chars().take(200).collect::<String>()
                ));
            }
        };
        let n = arr.len();
        all.extend(arr);
        if n < per_page {
            break; // last page
        }
    }
    Ok(all)
}

/// CLI path: `gh pr list --json …` — used when only keyring auth is
/// available, or as a fallback when REST fails.
fn fetch_prs_via_gh_cli(root: &Path) -> Vec<serde_json::Value> {
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
        _ => return vec![],
    };
    let s = String::from_utf8_lossy(&out);
    match serde_json::from_str::<serde_json::Value>(&s) {
        Ok(serde_json::Value::Array(a)) => a,
        _ => vec![],
    }
}

/// Ingest a Vec of PR JSON objects (either REST shape `merged_at`/`head.ref`
/// or gh-CLI shape `mergedAt`/`headRefName`) into `pr_index`. Idempotent
/// upsert on `pr_number`.
fn ingest_prs(conn: &Connection, prs: &[serde_json::Value]) -> Result<usize> {
    if prs.is_empty() {
        return Ok(0);
    }
    let tx = conn.unchecked_transaction()?;
    let ts = now_secs();
    let mut n = 0usize;
    for pr in prs {
        let number = pr.get("number").and_then(|v| v.as_i64()).unwrap_or(0);
        if number == 0 {
            continue;
        }
        let title = pr
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        // REST returns lowercase ("open"/"closed"); gh-CLI returns
        // uppercase ("OPEN"/"CLOSED"/"MERGED"). Normalize to uppercase +
        // promote closed-with-merged_at to MERGED so downstream detectors
        // can filter on state='MERGED' regardless of source.
        let state_raw = pr
            .get("state")
            .and_then(|v| v.as_str())
            .unwrap_or("UNKNOWN")
            .to_uppercase();
        // REST shape uses head.ref / base.ref / user.login; gh-CLI uses
        // headRefName / baseRefName / author.login.
        let head_ref = pr
            .get("headRefName")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                pr.get("head")
                    .and_then(|v| v.get("ref"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            });
        let base_ref = pr
            .get("baseRefName")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                pr.get("base")
                    .and_then(|v| v.get("ref"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            });
        let author = pr
            .get("author")
            .and_then(|v| v.get("login"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                pr.get("user")
                    .and_then(|v| v.get("login"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            });
        let created_at = pr
            .get("createdAt")
            .or_else(|| pr.get("created_at"))
            .and_then(|v| v.as_str())
            .and_then(parse_rfc3339_to_secs)
            .unwrap_or(0);
        let closed_at = pr
            .get("closedAt")
            .or_else(|| pr.get("closed_at"))
            .and_then(|v| v.as_str())
            .and_then(parse_rfc3339_to_secs);
        let merged_at = pr
            .get("mergedAt")
            .or_else(|| pr.get("merged_at"))
            .and_then(|v| v.as_str())
            .and_then(parse_rfc3339_to_secs);
        // Promote CLOSED-with-merged-at to MERGED for REST shape, which
        // returns state="closed" for merged PRs.
        let state = if merged_at.is_some() && state_raw == "CLOSED" {
            "MERGED".to_string()
        } else {
            state_raw
        };
        let additions = pr.get("additions").and_then(|v| v.as_i64()).unwrap_or(0);
        let deletions = pr.get("deletions").and_then(|v| v.as_i64()).unwrap_or(0);
        // REST list endpoint doesn't return file count; gh-CLI does.
        let changed_files = pr
            .get("changedFiles")
            .or_else(|| pr.get("changed_files"))
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
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

/// Result of `backfill_artifact_provenance`. Surfaces counts so the CLI
/// can report what fraction of artifacts now have introducing_pr populated.
#[derive(Debug, Clone, Default)]
pub struct ProvenanceBackfillResult {
    pub artifacts_total: usize,
    pub adding_commits_found: usize,
    pub introducing_pr_linked: usize,
    pub introducing_gap_linked: usize,
    /// Artifacts whose first-add commit pre-dates the oldest pr_index entry
    /// or could not be linked to a MERGED PR (truly unfindable).
    pub unlinkable_provenance: usize,
}

/// INFRA-2384: backfill `introducing_pr` + `introducing_gap` for every
/// artifact_index row that doesn't already have it set.
///
/// Algorithm:
///   1. Single `git log --diff-filter=A --pretty=format:COMMIT:%H:%at --name-only`
///      pass — records the oldest-add (commit, timestamp) for every path.
///   2. Load `(pr_number, gap_id, merged_at)` rows where state='MERGED',
///      sorted ascending by merged_at, into an in-memory vector.
///   3. For each artifact: bisect the PR vector for the smallest merged_at
///      >= adding_commit_ts → that's the introducing PR.
///   4. UPDATE artifact_index in a single transaction.
///
/// Cost: O(repo_commits) for the git-log pass + O(artifacts * log(prs)) for
/// the bisect. Target: <60s on 4500-artifact / 3000-PR repo. Never blocks
/// detector flow — failure returns Ok(default) so subsequent steps proceed.
pub fn backfill_artifact_provenance(
    conn: &Connection,
    root: &Path,
) -> Result<ProvenanceBackfillResult> {
    // ─── step 1: oldest-add commit per path ─────────────────────────────────
    let adding_commits = build_adding_commits_map(root);

    // ─── step 2: load merged-PR vector sorted by merged_at ──────────────────
    type PrEntry = (i64, i64, Option<String>); // (merged_at, pr_number, gap_id)
    let mut prs: Vec<PrEntry> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT merged_at, pr_number, gap_id FROM pr_index
             WHERE state = 'MERGED' AND merged_at IS NOT NULL
             ORDER BY merged_at ASC",
        )?;
        let mapped = stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        })?;
        for r in mapped {
            prs.push(r?);
        }
    }

    // ─── step 3: load artifacts needing backfill ────────────────────────────
    let mut artifact_rows: Vec<String> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT path FROM artifact_index
             WHERE introducing_pr IS NULL",
        )?;
        let mapped = stmt.query_map([], |r| r.get::<_, String>(0))?;
        for r in mapped {
            artifact_rows.push(r?);
        }
    }

    let mut result = ProvenanceBackfillResult {
        artifacts_total: artifact_rows.len(),
        ..Default::default()
    };

    // ─── step 4: bisect + UPDATE in a transaction ───────────────────────────
    let tx = conn.unchecked_transaction()?;
    for path in &artifact_rows {
        let adding_ts = match adding_commits.get(path) {
            Some(&ts) => {
                result.adding_commits_found += 1;
                ts
            }
            None => continue,
        };

        // Find first PR whose merged_at >= adding_ts. The merging PR (the
        // one that landed the adding commit on main) must have merged at or
        // after the commit was authored.
        let idx = prs.partition_point(|(merged_at, _, _)| *merged_at < adding_ts);
        if idx >= prs.len() {
            result.unlinkable_provenance += 1;
            continue;
        }
        let (_merged_at, pr_number, gap_id) = &prs[idx];

        tx.execute(
            "UPDATE artifact_index
             SET introducing_pr = ?1, introducing_gap = ?2
             WHERE path = ?3 AND introducing_pr IS NULL",
            params![pr_number, gap_id, path],
        )?;
        result.introducing_pr_linked += 1;
        if gap_id.is_some() {
            result.introducing_gap_linked += 1;
        }
    }
    tx.commit()?;

    // Artifacts with no adding-commit info contribute to unlinkable.
    let no_commit = result.artifacts_total - result.adding_commits_found;
    result.unlinkable_provenance += no_commit;
    Ok(result)
}

/// Walk `git log --diff-filter=A` over all history once and record the
/// oldest commit timestamp that ADDED each path. A path that has been
/// deleted-then-readded shows multiple A events; we keep the earliest
/// (the original introduction), since rebuild rotation usually wants
/// the first-shipped provenance.
///
/// Format: alternating header lines `COMMIT:<sha>:<unix_ts>` followed by
/// the file paths added by that commit (one per line). The single-quote
/// pretty format avoids any whitespace ambiguity.
fn build_adding_commits_map(root: &Path) -> HashMap<String, i64> {
    let mut map: HashMap<String, i64> = HashMap::new();
    let out = match Command::new("git")
        .args([
            "log",
            "--diff-filter=A",
            "--name-only",
            "--pretty=format:COMMIT:%H:%at",
            "--all",
        ])
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
        if let Some(rest) = line.strip_prefix("COMMIT:") {
            // COMMIT:<sha>:<unix_ts>
            if let Some((_sha, ts_str)) = rest.rsplit_once(':') {
                if let Ok(ts) = ts_str.parse::<i64>() {
                    current_ts = ts;
                }
            }
            continue;
        }
        if current_ts == 0 {
            continue;
        }
        // Keep the EARLIEST adding commit per path.
        map.entry(line.to_string())
            .and_modify(|first| {
                if current_ts < *first {
                    *first = current_ts;
                }
            })
            .or_insert(current_ts);
    }
    map
}

/// INFRA-2384: recompute `activation_state` + `reference_count` +
/// `referenced_from` for every artifact_index row using PR provenance.
///
/// Rules:
///   * If introducing_pr is set AND artifact has ≥3 inbound references → `referenced`
///   * If introducing_pr is set AND artifact has 1-2 inbound references → `dormant`
///   * If introducing_pr is set AND artifact has 0 inbound references → `orphan`
///   * If introducing_pr IS NULL (truly unfindable) → `unknown`
///
/// References are computed via `git grep -l -F` on the basename for files
/// under `scripts/`, `src/`, `launchd/`, and `migrations/`. Bounded to
/// substrate paths to avoid scanning vendored deps + node_modules.
///
/// Returns the number of rows whose activation_state was updated.
pub fn recompute_activation_with_provenance(conn: &Connection, root: &Path) -> Result<usize> {
    // Load all artifacts.
    let mut rows: Vec<(String, Option<i64>)> = Vec::new();
    {
        let mut stmt = conn.prepare("SELECT path, introducing_pr FROM artifact_index")?;
        let mapped = stmt.query_map([], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, Option<i64>>(1)?))
        })?;
        for r in mapped {
            rows.push(r?);
        }
    }

    let tx = conn.unchecked_transaction()?;
    let mut updated = 0usize;
    for (path, intro_pr) in &rows {
        // Truly unfindable provenance → unknown (until backfill can resolve it).
        if intro_pr.is_none() {
            tx.execute(
                "UPDATE artifact_index
                 SET activation_state='unknown'
                 WHERE path=?1",
                params![path],
            )?;
            updated += 1;
            continue;
        }

        // Only scan reference counts for substrate paths; skip vendored.
        let scan_eligible = path.starts_with("src/")
            || path.starts_with("scripts/")
            || path.starts_with("launchd/")
            || path.starts_with("migrations/")
            || path.starts_with("docs/gaps/")
            || path.starts_with("crates/");
        if !scan_eligible {
            // Keep prior state; don't churn references for irrelevant paths.
            continue;
        }

        let basename = match Path::new(path).file_name() {
            Some(b) => b.to_string_lossy().to_string(),
            None => continue,
        };

        let exit = Command::new("git")
            .args([
                "grep", "-l", "-F", "--", &basename, "*.rs", "*.sh", "*.md", "*.yaml", "*.yml",
                "*.plist", "*.toml",
            ])
            .current_dir(root)
            .output();

        let referrers: Vec<String> = match exit {
            Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|l| !l.is_empty() && *l != path)
                .map(|l| l.to_string())
                .collect(),
            _ => Vec::new(),
        };

        let count = referrers.len();
        let activation = if count == 0 {
            "orphan"
        } else if count <= 2 {
            "dormant"
        } else {
            "referenced"
        };
        let referrers_json = serde_json::to_string(&referrers).unwrap_or_else(|_| "[]".to_string());
        tx.execute(
            "UPDATE artifact_index
             SET activation_state=?1, reference_count=?2, referenced_from=?3
             WHERE path=?4",
            params![activation, count as i64, referrers_json, path],
        )?;
        updated += 1;
    }
    tx.commit()?;
    Ok(updated)
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
///
/// Compatibility wrapper: callers that don't know PR-collection state
/// proceed as before; pr_index is queried and the 3 dependent detectors
/// are auto-skipped when empty (INFRA-2368).
pub fn run_detectors(conn: &Connection, root: &Path) -> Result<usize> {
    let pr_count = pr_index_count(conn).unwrap_or(0);
    run_detectors_v2(conn, root, pr_count > 0)
}

/// Returns the count of rows in `pr_index`. Used by `run_detectors_v2`
/// to skip the 3 PR-dependent detectors when the index is empty
/// (INFRA-2368: prevents silent zero-findings when gh auth missing).
pub fn pr_index_count(conn: &Connection) -> Result<i64> {
    conn.query_row("SELECT COUNT(*) FROM pr_index", [], |r| r.get::<_, i64>(0))
        .with_context(|| "counting pr_index rows")
}

/// Detector classes that depend on `pr_index` being populated. When PR
/// collection skipped (gh auth missing), these are disabled — we explicitly
/// mark them as such in the class-stats output instead of silently
/// reporting zero findings.
pub const PR_DEPENDENT_DETECTORS: &[&str] = &[
    "doc-only-feature",
    "unreferenced-gap",
    "long-undormant-substrate",
];

/// v2 entry point: takes an explicit `prs_available` flag from the
/// PR-collection step. When false, the 3 PR-dependent detectors are
/// skipped (with a single ambient `kind=detector_disabled` per-class
/// event) and a class-level note is written to `finding_class_tiers`.
pub fn run_detectors_v2(conn: &Connection, root: &Path, prs_available: bool) -> Result<usize> {
    let mut total = 0;
    total += detect_orphan_artifacts(conn, root)?;
    total += detect_dormant_scripts(conn, root)?;
    total += detect_dead_rust_mods(conn, root)?;
    total += detect_stale_plists(conn, root)?;
    if prs_available {
        total += detect_doc_only_features(conn, root)?;
        total += detect_unreferenced_gaps(conn, root)?;
        total += detect_long_undormant_substrate(conn, root)?;
        // Clear any prior "disabled" marker if PRs are now flowing again.
        clear_pr_dependent_disabled_marker(conn);
    } else {
        record_pr_dependent_disabled_marker(conn);
        for class in PR_DEPENDENT_DETECTORS {
            emit_detector_disabled_event(class, "pr_index empty (gh auth missing)");
        }
    }
    total += detect_shadow_duplicates(conn, root)?;
    total += detect_event_kind_zero_emits(conn, root)?;
    Ok(total)
}

/// Record a per-class marker in `inventory_meta` indicating that the
/// PR-dependent detectors were skipped on the last rebuild. CLI surfaces
/// this in `class-stats` output as `(disabled — gh auth missing)`.
fn record_pr_dependent_disabled_marker(conn: &Connection) {
    let _ = conn.execute(
        "INSERT INTO inventory_meta (key, value) VALUES ('pr_dependent_detectors_disabled', '1')
         ON CONFLICT(key) DO UPDATE SET value='1'",
        [],
    );
}

/// Clear the disabled marker (PR collection succeeded on this rebuild).
fn clear_pr_dependent_disabled_marker(conn: &Connection) {
    let _ = conn.execute(
        "INSERT INTO inventory_meta (key, value) VALUES ('pr_dependent_detectors_disabled', '0')
         ON CONFLICT(key) DO UPDATE SET value='0'",
        [],
    );
}

/// Public read for the CLI: is the disabled marker currently set?
pub fn pr_dependent_detectors_disabled(conn: &Connection) -> bool {
    let v: Option<String> = conn
        .query_row(
            "SELECT value FROM inventory_meta WHERE key='pr_dependent_detectors_disabled'",
            [],
            |r| r.get(0),
        )
        .optional()
        .ok()
        .flatten();
    matches!(v.as_deref(), Some("1"))
}

/// Emit a kind=detector_disabled event so the observability lane can see
/// the cohort. Best-effort — failure to write doesn't block detectors.
fn emit_detector_disabled_event(finding_class: &str, reason: &str) {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let json = format!(
        r#"{{"ts":"{}","kind":"detector_disabled","finding_class":"{}","reason":"{}"}}"#,
        ts,
        json_escape(finding_class),
        json_escape(reason),
    );
    let path = ambient_log_path();
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{}", json);
    }
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

/// Detector 5: doc-only-feature — gap shipped with a `feat:` title but no
/// code artifact in `artifact_index` references the PR number in its
/// provenance (introducing_pr). Surfaces "we said we shipped a feature but
/// only the docs landed" cases.
///
/// Heuristic (INFRA-2368):
///   1. Find merged PRs whose title starts with `feat(` or `feat:`.
///   2. For each, count artifacts where introducing_pr = this PR.
///   3. If count > 0 AND all introducing artifacts are class='doc', flag.
///   4. If count == 0 AND files_changed available AND files_changed == 1
///      AND the PR's domain is CREDIBLE/EFFECTIVE (high-signal subset),
///      also flag — covers the gh-CLI path that has files_changed.
fn detect_doc_only_features(conn: &Connection, _root: &Path) -> Result<usize> {
    type FeatPrRow = (i64, String, Option<String>, i64, Option<String>);
    let mut feat_prs: Vec<FeatPrRow> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT pr_number, title, gap_id, files_changed, domain FROM pr_index
             WHERE state = 'MERGED'
               AND (LOWER(title) LIKE 'feat(%' OR LOWER(title) LIKE 'feat:%')
             ORDER BY merged_at DESC NULLS LAST
             LIMIT 500",
        )?;
        let mapped = stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, Option<String>>(4)?,
            ))
        })?;
        for r in mapped {
            feat_prs.push(r?);
        }
    }
    let mut n = 0usize;
    for (pr_number, title, gap_id, files_changed, domain) in feat_prs {
        // Count introducing artifacts whose class differs from 'doc'.
        let non_doc: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM artifact_index
                 WHERE introducing_pr = ?1 AND class != 'doc'",
                params![pr_number],
                |r| r.get::<_, i64>(0),
            )
            .unwrap_or(0);
        let any_intro: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM artifact_index WHERE introducing_pr = ?1",
                params![pr_number],
                |r| r.get::<_, i64>(0),
            )
            .unwrap_or(0);
        // Signal 1: artifact_index records this PR as the introducer of
        // ≥1 artifact AND none of those artifacts are code.
        let signal_artifact = any_intro > 0 && non_doc == 0;
        // Signal 2: gh-CLI path provided files_changed=1 and the PR's
        // domain is in the high-signal subset where we'd expect code.
        let signal_files =
            files_changed == 1 && matches!(domain.as_deref(), Some("CREDIBLE") | Some("EFFECTIVE"));
        if !(signal_artifact || signal_files) {
            continue;
        }
        let reason = if signal_artifact {
            "all introduced artifacts are docs"
        } else {
            "files_changed=1 in code-expected domain"
        };
        let f = Finding {
            finding_class: "doc-only-feature".to_string(),
            severity: "info".to_string(),
            artifact_path: None,
            pr_number: Some(pr_number),
            gap_id,
            detail: format!("feat PR #{pr_number} looks doc-only ({reason}): {title}"),
            evidence_json: None,
        };
        insert_finding(conn, &f)?;
        n += 1;
    }
    Ok(n)
}

/// Detector 6: unreferenced-gap — gap exists in the gap registry but no
/// PR in `pr_index` has a title containing it.
///
/// Per INFRA-2368 spec: "gap_id from gap registry with no PR in pr_index
/// whose title contains it". Strengthens the prior heuristic (which also
/// produced findings for gaps with *some* PRs whose artifacts went orphan
/// — that signal is preserved as a secondary case).
///
/// Two emission paths:
///   * Primary: gap_id present in `docs/gaps/*.yaml` (cheap glob count)
///     with zero matching pr_index row.
///   * Secondary (legacy): merged gap whose introducing_gap artifacts
///     are all orphan now — kept for backward compatibility with
///     existing test fixtures.
fn detect_unreferenced_gaps(conn: &Connection, root: &Path) -> Result<usize> {
    let mut n = 0usize;

    // ─── Primary signal: scan gap registry yaml glob ────────────────────────
    let gaps_dir = root.join("docs/gaps");
    let registered: Vec<String> = match fs::read_dir(&gaps_dir) {
        Ok(it) => it
            .filter_map(|e| e.ok())
            .filter_map(|e| {
                let p = e.path();
                if p.extension().and_then(|s| s.to_str()) != Some("yaml") {
                    return None;
                }
                p.file_stem()
                    .and_then(|s| s.to_str())
                    .map(|s| s.to_string())
            })
            .filter(|stem| extract_gap_id(stem).is_some())
            .take(5000)
            .collect(),
        Err(_) => Vec::new(),
    };

    let cutoff_age = now_secs() - 30 * 86400; // skip very-new gaps
    for gap_id in &registered {
        // Count PRs whose title contains the gap id.
        let pr_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM pr_index WHERE title LIKE ?1",
                params![format!("%{}%", gap_id)],
                |r| r.get::<_, i64>(0),
            )
            .unwrap_or(0);
        if pr_count > 0 {
            continue;
        }
        // Skip gaps without an age signal (yaml mtime as a stand-in;
        // brand-new gaps shouldn't surface as unreferenced).
        let yaml_path = gaps_dir.join(format!("{}.yaml", gap_id));
        if let Ok(meta) = fs::metadata(&yaml_path) {
            if let Ok(modified) = meta.modified() {
                if let Ok(d) = modified.duration_since(UNIX_EPOCH) {
                    if (d.as_secs() as i64) > cutoff_age {
                        continue; // gap filed in last 30d, skip
                    }
                }
            }
        }
        let f = Finding {
            finding_class: "unreferenced-gap".to_string(),
            severity: "low".to_string(),
            artifact_path: None,
            pr_number: None,
            gap_id: Some(gap_id.clone()),
            detail: format!(
                "Gap {gap_id} is registered in docs/gaps but no PR title references it"
            ),
            evidence_json: None,
        };
        insert_finding(conn, &f)?;
        n += 1;
        if n >= 500 {
            break; // bound emission
        }
    }

    // ─── Secondary signal: merged gap whose introducing artifacts orphaned ─
    let cutoff = now_secs() - 30 * 86400;
    let mut legacy_rows: Vec<(String, i64)> = Vec::new();
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
            legacy_rows.push(r?);
        }
    }
    for (gap_id, pr_number) in legacy_rows {
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

/// Detector 7: long-undormant-substrate — artifact whose
/// `last_modified_at` is > 90d ago AND not already classified as
/// removed/superseded in `tech_debt_findings`.
///
/// Per INFRA-2368 spec: "artifacts whose `last_pr_touched` is > 90 days
/// ago AND not in `tech_debt_findings` as removed/superseded". We use
/// `last_modified_at` from artifact_index (populated by git-log walk in
/// `collect_artifacts`) as the "last PR touched" proxy.
///
/// Bounded to substrate paths (src/, scripts/coord/, scripts/dispatch/)
/// to avoid flooding on docs/yaml drift.
fn detect_long_undormant_substrate(conn: &Connection, _root: &Path) -> Result<usize> {
    let cutoff = now_secs() - 90 * 86400;

    let mut rows: Vec<(String, String, i64)> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT a.path, a.class, a.last_modified_at
             FROM artifact_index a
             WHERE a.last_modified_at < ?1
               AND a.last_modified_at > 0
               AND (a.path LIKE 'src/%'
                    OR a.path LIKE 'scripts/coord/%'
                    OR a.path LIKE 'scripts/dispatch/%')
               AND NOT EXISTS (
                   SELECT 1 FROM tech_debt_findings tdf
                   WHERE tdf.artifact_path = a.path
                     AND tdf.operator_classification = 'REAL_POSITIVE'
                     AND (tdf.operator_note LIKE '%removed%'
                          OR tdf.operator_note LIKE '%superseded%')
               )
             ORDER BY a.last_modified_at ASC
             LIMIT 200",
        )?;
        let mapped = stmt.query_map([cutoff], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })?;
        for r in mapped {
            rows.push(r?);
        }
    }

    let mut n = 0usize;
    let now = now_secs();
    for (path, class, last_modified_at) in rows {
        let days_ago = (now - last_modified_at) / 86400;
        let f = Finding {
            finding_class: "long-undormant-substrate".to_string(),
            severity: "info".to_string(),
            artifact_path: Some(path.clone()),
            pr_number: None,
            gap_id: None,
            detail: format!(
                "{} ({}) last touched {}d ago — review whether substrate accreted users",
                path, class, days_ago
            ),
            evidence_json: None,
        };
        insert_finding(conn, &f)?;
        n += 1;
    }

    // Legacy signal: merged PRs >90d with substrate/infra titles (kept
    // for the existing CLI surfacing pattern; cheaper than the artifact
    // scan when pr_index is heavily populated).
    let mut pr_rows: Vec<(i64, String, String)> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT pr_number, title, COALESCE(gap_id, '') FROM pr_index
             WHERE state = 'MERGED'
               AND merged_at < ?1
               AND (LOWER(title) LIKE '%substrate%' OR LOWER(title) LIKE '%infra-%')
             LIMIT 100",
        )?;
        let mapped = stmt.query_map([cutoff], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?;
        for r in mapped {
            pr_rows.push(r?);
        }
    }
    for (pr_number, title, gap_id) in pr_rows {
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
