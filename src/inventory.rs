//! META-271 / INFRA-2367 / INFRA-2368 / INFRA-2370 / INFRA-2375-2385 — Fleet Inventory + Tech-Debt Audit DB.
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
//! Detectors (10 classes, all tier=0 by default):
//!   1. orphan-artifact           — artifact has zero inbound references (now scans docs/ + plugin-glob patterns, INFRA-2375)
//!   2. dormant-script            — shell script with ≤1 inbound text-grep reference across docs+scripts+src+.claude (INFRA-2376)
//!   3. dead-rust-mod             — Rust module declared in mod.rs/lib.rs but never reachable from a binary
//!   4. stale-plist               — launchd plist whose binary doesn't exist (skips template files with sibling installers, INFRA-2378)
//!   5. doc-only-feature          — gap shipped a doc but no code change touched the named subsystem
//!   6. unreferenced-gap          — gap shipped >30d ago but its artifacts are orphans
//!   7. long-undormant-substrate  — substrate idle ≥CHUMP_INVENTORY_DORMANT_DAYS (default 30, INFRA-2383)
//!   8. shadow-duplicate          — pair sharing prefix AND high content-jaccard, allowlisted siblings excluded (INFRA-2377)
//!   9. event-kind-zero-emit      — EVENT_REGISTRY kind with zero source emit-sites (INFRA-2379)
//!  10. ghost-gap-reference       — PR title references gap_id with no docs/gaps/<X>.yaml on disk (INFRA-2382)
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

/// The 10 detector class names. Used for seeding finding_class_tiers and
/// validating operator input. INFRA-2382 added `ghost-gap-reference`.
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
    "ghost-gap-reference",
];

/// INFRA-2383: long-undormant cutoff (days). Default 30 (was 90 — the
/// active repo refreshes substrate often enough that 90d catches almost
/// nothing). Env-tunable for cadence variants.
fn dormant_days_threshold() -> i64 {
    std::env::var("CHUMP_INVENTORY_DORMANT_DAYS")
        .ok()
        .and_then(|s| s.parse::<i64>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(30)
}

/// INFRA-2377: allowlist of intentional sibling-naming patterns that
/// share basename prefixes by design (version variants, role-stamped
/// variants). Pairs whose paths match any of these patterns are NOT
/// flagged as shadow-duplicate even when prefixes collide.
const SHADOW_DUPLICATE_SIBLING_PATTERNS: &[&str] = &[
    // Version variants: pr-rescue-v1.sh / pr-rescue-v2.sh
    "-v1.",
    "-v2.",
    "-v3.",
    // Role-stamped: worker.sh / worker-haiku.sh
    "-haiku.",
    "-sonnet.",
    "-opus.",
    // Install/uninstall pairs
    "install-",
    "uninstall-",
    // Test-fixture suffixes
    "-test.",
    "-fixture.",
    "-dry-run.",
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
    /// INFRA-2385: how many artifacts were attributed via the merge-graph
    /// path (high-precision; handles admin-merge ordering correctly).
    pub graph_resolved_count: usize,
    /// INFRA-2385: how many artifacts fell through to the time-based bisect
    /// (legacy path; lower precision, but still better than nothing).
    pub bisect_fallback_count: usize,
}

/// INFRA-2384/INFRA-2385: backfill `introducing_pr` + `introducing_gap` for
/// every artifact_index row that doesn't already have it set.
///
/// Algorithm v2 (INFRA-2385 BUG-1 fix — merge-graph traversal):
///   1. Single `git log --diff-filter=A --pretty=format:COMMIT:%H:%at --name-only`
///      pass — records the oldest-add (commit, sha, timestamp) for every path.
///   2. Build a `commit_sha → pr_number` map by walking `git log --merges`
///      on main and parsing the PR number from merge-commit subjects
///      (`Merge pull request #N` OR squash-style `(#N)` token). For every
///      ancestor commit of that merge, the merging PR is the one that
///      brought it onto main. This is the `git log --ancestry-path` substitute
///      that handles admin-merge ordering correctly: the merge commit's SHA
///      is what we look up, not its timestamp.
///   3. Load `(pr_number, gap_id, merged_at)` rows from pr_index for the
///      time-based FALLBACK path (used when the graph lookup misses).
///   4. For each artifact: prefer the graph map; fall back to the bisect.
///      On fallback, emit `kind=provenance_fallback` to ambient.jsonl.
///   5. UPDATE artifact_index in a single transaction.
///
/// Cost: O(repo_commits) for the git-log passes + O(artifacts) for the
/// HashMap lookup, with O(log prs) fallback bisect. Target: <90s on
/// 4500-artifact / 3000-PR repo. Never blocks detector flow.
pub fn backfill_artifact_provenance(
    conn: &Connection,
    root: &Path,
) -> Result<ProvenanceBackfillResult> {
    // ─── step 1: oldest-add (sha, ts) per path ─────────────────────────────
    let adding_commits = build_adding_commits_map_v2(root);

    // ─── step 2: commit_sha → pr_number via merge-graph walk (INFRA-2385) ──
    let commit_to_pr = build_commit_to_pr_map(root);

    // ─── step 3: load merged-PR vector sorted by merged_at (fallback) ──────
    type PrEntry = (i64, i64, Option<String>); // (merged_at, pr_number, gap_id)
    let mut prs_by_time: Vec<PrEntry> = Vec::new();
    let mut pr_meta: HashMap<i64, Option<String>> = HashMap::new(); // pr_number -> gap_id
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
            let (mt, num, gap) = r?;
            pr_meta.insert(num, gap.clone());
            prs_by_time.push((mt, num, gap));
        }
    }
    // Also include open/unmerged PRs in the meta map so graph-resolved hits
    // can still attach a gap_id even if merged_at is NULL.
    {
        let mut stmt =
            conn.prepare("SELECT pr_number, gap_id FROM pr_index WHERE merged_at IS NULL")?;
        let mapped = stmt.query_map([], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?))
        })?;
        for r in mapped {
            let (num, gap) = r?;
            pr_meta.entry(num).or_insert(gap);
        }
    }

    // ─── step 4: load artifacts needing backfill ───────────────────────────
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

    // ─── step 5: lookup + UPDATE in a transaction ──────────────────────────
    let tx = conn.unchecked_transaction()?;
    for path in &artifact_rows {
        let (adding_sha, adding_ts) = match adding_commits.get(path) {
            Some(v) => {
                result.adding_commits_found += 1;
                v.clone()
            }
            None => continue,
        };

        // Primary: merge-graph lookup (handles admin-merge ordering).
        let (pr_number, gap_id, used_fallback) =
            if let Some(&pr_num) = commit_to_pr.get(&adding_sha) {
                let gap = pr_meta.get(&pr_num).cloned().flatten();
                (Some(pr_num), gap, false)
            } else {
                // Fallback: time-based partition_point. Emit a transient
                // provenance_fallback ambient event so the operator can
                // see the cohort that needs merge-commit auth.
                let idx = prs_by_time.partition_point(|(merged_at, _, _)| *merged_at < adding_ts);
                if idx >= prs_by_time.len() {
                    emit_provenance_fallback(path, "no_pr_after_adding_ts");
                    result.unlinkable_provenance += 1;
                    continue;
                }
                let (_mt, pr_num, gap) = &prs_by_time[idx];
                emit_provenance_fallback(path, "merge_graph_miss");
                result.bisect_fallback_count += 1;
                (Some(*pr_num), gap.clone(), true)
            };

        if let Some(pr_num) = pr_number {
            tx.execute(
                "UPDATE artifact_index
                 SET introducing_pr = ?1, introducing_gap = ?2
                 WHERE path = ?3 AND introducing_pr IS NULL",
                params![pr_num, gap_id, path],
            )?;
            result.introducing_pr_linked += 1;
            if gap_id.is_some() {
                result.introducing_gap_linked += 1;
            }
            if !used_fallback {
                result.graph_resolved_count += 1;
            }
        }
    }
    tx.commit()?;

    // Artifacts with no adding-commit info contribute to unlinkable.
    let no_commit = result.artifacts_total - result.adding_commits_found;
    result.unlinkable_provenance += no_commit;
    Ok(result)
}

/// INFRA-2385: emit `kind=provenance_fallback` to ambient.jsonl. Used when
/// the merge-graph lookup misses and we fall back to the bisect. Lets the
/// operator see how many artifacts are still on the legacy attribution path.
fn emit_provenance_fallback(path: &str, reason: &str) {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let json = format!(
        r#"{{"ts":"{}","kind":"provenance_fallback","path":"{}","reason":"{}"}}"#,
        ts,
        json_escape(path),
        json_escape(reason),
    );
    let log = ambient_log_path();
    if let Some(parent) = log.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&log) {
        let _ = writeln!(f, "{}", json);
    }
}

/// INFRA-2385: walk `git log --merges --first-parent main` AND `git log --first-parent main`
/// (covers both true-merge and squash-merge histories). For each first-parent
/// commit whose subject contains a PR number (either `Merge pull request #N`
/// or `(#N)` at end of subject), enumerate every ancestor commit reachable
/// from that commit but NOT from its parent on first-parent — that commit
/// belongs to that PR.
///
/// Returns `commit_sha → pr_number`. Handles admin-merge ordering correctly
/// because the lookup is by SHA, not by timestamp.
fn build_commit_to_pr_map(root: &Path) -> HashMap<String, i64> {
    let mut map: HashMap<String, i64> = HashMap::new();

    // Walk first-parent commits on main; parse subjects for PR numbers.
    // Format: <sha>\t<parent_count>\t<subject>
    let out = Command::new("git")
        .args([
            "log",
            "--first-parent",
            "origin/main",
            "--pretty=format:%H\t%P\t%s",
        ])
        .current_dir(root)
        .output();
    let stdout = match out {
        Ok(o) if o.status.success() => o.stdout,
        _ => return map,
    };
    let s = String::from_utf8_lossy(&stdout);

    for line in s.lines() {
        let mut parts = line.splitn(3, '\t');
        let sha = match parts.next() {
            Some(x) if !x.is_empty() => x,
            _ => continue,
        };
        let parents = parts.next().unwrap_or("");
        let subject = parts.next().unwrap_or("");
        let pr_num = match extract_pr_number_from_subject(subject) {
            Some(n) => n,
            None => continue,
        };

        // Every first-parent commit IS attributed to its PR (squash merges
        // leave only one commit per PR, so that single commit IS the file-
        // add commit). Insert the first-parent commit itself.
        map.insert(sha.to_string(), pr_num);

        // For true-merge commits (≥2 parents), enumerate the side-branch:
        // commits reachable from <sha>^2 but not <sha>^1.
        let parent_list: Vec<&str> = parents.split_whitespace().collect();
        if parent_list.len() >= 2 {
            let arg = format!("{}^2", sha);
            let exclude = format!("^{}^1", sha);
            let out2 = Command::new("git")
                .args(["rev-list", &arg, &exclude])
                .current_dir(root)
                .output();
            if let Ok(o) = out2 {
                if o.status.success() {
                    for c in String::from_utf8_lossy(&o.stdout).lines() {
                        let c = c.trim();
                        if !c.is_empty() {
                            map.entry(c.to_string()).or_insert(pr_num);
                        }
                    }
                }
            }
        }
    }
    map
}

/// Extract a PR number from a merge-commit / squash subject. Handles:
///   * "Merge pull request #1234 from foo"
///   * "feat(INFRA-2367): foo (#1234)"
///   * "fix(...): bar (#1234)"
///
/// Returns None when no `#NNN` pattern is found.
fn extract_pr_number_from_subject(subject: &str) -> Option<i64> {
    // Prefer the trailing `(#NNN)` token (squash-merge default).
    if let Some(start) = subject.rfind("(#") {
        let tail = &subject[start + 2..];
        if let Some(end) = tail.find(')') {
            if let Ok(n) = tail[..end].parse::<i64>() {
                return Some(n);
            }
        }
    }
    // Fall back to "Merge pull request #NNN".
    if let Some(idx) = subject.find("pull request #") {
        let tail = &subject[idx + "pull request #".len()..];
        let mut end = 0;
        for (i, c) in tail.char_indices() {
            if c.is_ascii_digit() {
                end = i + c.len_utf8();
            } else {
                break;
            }
        }
        if end > 0 {
            if let Ok(n) = tail[..end].parse::<i64>() {
                return Some(n);
            }
        }
    }
    None
}

/// INFRA-2385: walk `git log --diff-filter=A` and return BOTH the adding
/// commit SHA and timestamp for each path. The SHA is the load-bearing
/// field for the merge-graph lookup (commit_to_pr map); the timestamp is
/// retained for the bisect fallback.
fn build_adding_commits_map_v2(root: &Path) -> HashMap<String, (String, i64)> {
    let mut map: HashMap<String, (String, i64)> = HashMap::new();
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

    let mut current_sha = String::new();
    let mut current_ts: i64 = 0;
    for line in s.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("COMMIT:") {
            // COMMIT:<sha>:<unix_ts>
            if let Some((sha, ts_str)) = rest.rsplit_once(':') {
                if let Ok(ts) = ts_str.parse::<i64>() {
                    current_sha = sha.to_string();
                    current_ts = ts;
                }
            }
            continue;
        }
        if current_ts == 0 || current_sha.is_empty() {
            continue;
        }
        // Keep the EARLIEST adding commit per path.
        let new_sha = current_sha.clone();
        let new_ts = current_ts;
        map.entry(line.to_string())
            .and_modify(|(sha, ts)| {
                if new_ts < *ts {
                    *sha = new_sha.clone();
                    *ts = new_ts;
                }
            })
            .or_insert((new_sha, new_ts));
    }
    map
}

/// INFRA-2384/INFRA-2385: recompute `activation_state` + `reference_count` +
/// `referenced_from` for every artifact_index row using PR provenance.
///
/// Rules:
///   * If introducing_pr is set AND artifact has ≥3 inbound references → `referenced`
///   * If introducing_pr is set AND artifact has 1-2 inbound references → `dormant`
///   * If introducing_pr is set AND artifact has 0 inbound references → `orphan`
///   * If introducing_pr IS NULL (truly unfindable) → `unknown`
///
/// INFRA-2385 BUG-3 fix: reference detection now also catches:
///   * Rust `mod X;` / `pub mod X;` declarations naming the file stem in
///     main.rs/lib.rs/mod.rs (Rust submodule wiring)
///   * Rust `include_str!("path/to/file.sql")` literals and embedded
///     `.sql` filename references
///   * Shell `source <path>` / `./lib/<stem>.sh` / `bash <stem>.sh`
///     invocations within sibling scripts
///   * Docs grep (INFRA-2375): scans docs/**/*.md too, not just code
///   * Plugin-glob aware (INFRA-2375): tolerates `scripts/<group>/*.sh`
///     and `crates/*/src/<name>.rs` style references
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

        let referrers = collect_referrers_v2(root, path);
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

/// INFRA-2385 BUG-3 / INFRA-2375 / INFRA-2376: collect inbound referrers for
/// an artifact, including:
///   * basename grep (legacy) across .rs/.sh/.md/.yaml/.yml/.plist/.toml
///   * docs/ markdown grep (INFRA-2375)
///   * .claude/ agent docs grep (INFRA-2376)
///   * Rust `mod X;` / `pub mod X;` declarations naming the file stem
///   * SQL `include_str!("...")` literals matching artifact path
///   * Shell `source <path>` / `./lib/<stem>` / `bash <stem>.sh` patterns
///   * Plugin-glob: a referrer file containing `scripts/<group>/*.sh` or
///     `crates/*/src/<name>.rs` patterns that match the artifact path
///
/// Self-references are excluded. Each path appears at most once in the
/// returned vector.
fn collect_referrers_v2(root: &Path, path: &str) -> Vec<String> {
    use std::collections::HashSet;
    let mut set: HashSet<String> = HashSet::new();

    let basename = match Path::new(path).file_name() {
        Some(b) => b.to_string_lossy().to_string(),
        None => return Vec::new(),
    };
    let stem = Path::new(path)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();

    // Pass 1: basename grep across code + docs + .claude (INFRA-2375/2376).
    // Note: leaving `--` so `git grep` treats subsequent items as pathspecs.
    let exit = Command::new("git")
        .args([
            "grep", "-l", "-F", "--", &basename, "*.rs", "*.sh", "*.md", "*.yaml", "*.yml",
            "*.plist", "*.toml", "*.sql",
        ])
        .current_dir(root)
        .output();
    if let Ok(o) = exit {
        if o.status.success() {
            for r in String::from_utf8_lossy(&o.stdout).lines() {
                if !r.is_empty() && r != path {
                    set.insert(r.to_string());
                }
            }
        }
    }

    // Pass 2: Rust `mod X;` / `pub mod X;` declarations for Rust artifacts.
    if path.ends_with(".rs") && !stem.is_empty() && stem != "mod" && stem != "lib" && stem != "main"
    {
        let pat = format!("mod {};", stem);
        let exit = Command::new("git")
            .args(["grep", "-l", "-F", "--", &pat, "*.rs"])
            .current_dir(root)
            .output();
        if let Ok(o) = exit {
            if o.status.success() {
                for r in String::from_utf8_lossy(&o.stdout).lines() {
                    if !r.is_empty() && r != path {
                        set.insert(r.to_string());
                    }
                }
            }
        }
        let pat_pub = format!("pub mod {};", stem);
        let exit2 = Command::new("git")
            .args(["grep", "-l", "-F", "--", &pat_pub, "*.rs"])
            .current_dir(root)
            .output();
        if let Ok(o) = exit2 {
            if o.status.success() {
                for r in String::from_utf8_lossy(&o.stdout).lines() {
                    if !r.is_empty() && r != path {
                        set.insert(r.to_string());
                    }
                }
            }
        }
    }

    // Pass 3: Rust `include_str!("<path>")` literals for any artifact.
    let inc_pat = format!("include_str!(\"{}\"", path);
    let exit3 = Command::new("git")
        .args(["grep", "-l", "-F", "--", &inc_pat, "*.rs"])
        .current_dir(root)
        .output();
    if let Ok(o) = exit3 {
        if o.status.success() {
            for r in String::from_utf8_lossy(&o.stdout).lines() {
                if !r.is_empty() && r != path {
                    set.insert(r.to_string());
                }
            }
        }
    }
    // Also: include_str!("relative/path") — match by basename token in any .rs.
    if path.ends_with(".sql") || path.ends_with(".yaml") || path.ends_with(".md") {
        let inc_basename = format!("include_str!(\"{}", basename);
        let exit4 = Command::new("git")
            .args(["grep", "-l", "-F", "--", &inc_basename, "*.rs"])
            .current_dir(root)
            .output();
        if let Ok(o) = exit4 {
            if o.status.success() {
                for r in String::from_utf8_lossy(&o.stdout).lines() {
                    if !r.is_empty() && r != path {
                        set.insert(r.to_string());
                    }
                }
            }
        }
    }

    // Pass 4: sibling shell `source <path>` / `./<basename>` / `bash <basename>`.
    if path.ends_with(".sh") || path.ends_with(".bash") {
        for pat in &[
            format!("source {}", path),
            format!("./{}", path),
            format!("bash {}", path),
        ] {
            let exit = Command::new("git")
                .args(["grep", "-l", "-F", "--", pat, "*.sh", "*.bash"])
                .current_dir(root)
                .output();
            if let Ok(o) = exit {
                if o.status.success() {
                    for r in String::from_utf8_lossy(&o.stdout).lines() {
                        if !r.is_empty() && r != path {
                            set.insert(r.to_string());
                        }
                    }
                }
            }
        }
        // Also catch `lib/<basename>` style for shared helpers.
        let lib_pat = format!("lib/{}", basename);
        let exit_lib = Command::new("git")
            .args(["grep", "-l", "-F", "--", &lib_pat, "*.sh", "*.bash"])
            .current_dir(root)
            .output();
        if let Ok(o) = exit_lib {
            if o.status.success() {
                for r in String::from_utf8_lossy(&o.stdout).lines() {
                    if !r.is_empty() && r != path {
                        set.insert(r.to_string());
                    }
                }
            }
        }
    }

    // Pass 5: plugin-glob references (INFRA-2375). A file containing
    // `scripts/<group>/*.sh` is considered a referrer for every script
    // under that group.
    let parent = Path::new(path).parent().and_then(|p| p.to_str());
    if let Some(parent_dir) = parent {
        let glob_pat = format!("{}/*", parent_dir);
        let exit = Command::new("git")
            .args([
                "grep", "-l", "-F", "--", &glob_pat, "*.rs", "*.sh", "*.md", "*.yaml", "*.yml",
            ])
            .current_dir(root)
            .output();
        if let Ok(o) = exit {
            if o.status.success() {
                for r in String::from_utf8_lossy(&o.stdout).lines() {
                    if !r.is_empty() && r != path {
                        set.insert(r.to_string());
                    }
                }
            }
        }
    }

    let mut out: Vec<String> = set.into_iter().collect();
    out.sort();
    out
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
    // INFRA-2382: ghost-gap-reference. Reads pr_index (not gh-auth-gated)
    // and the docs/gaps/ slice of artifact_index.
    total += detect_ghost_gap_references(conn, root)?;
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
///
/// INFRA-2375 calibration: reference detection now widens the grep to docs/
/// markdown, .claude/ agent docs, Rust mod declarations, SQL include_str
/// literals, plugin-glob patterns. RP target: ≥30% (was 0% across 20 samples).
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
        let referrers = collect_referrers_v2(root, &path);

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

/// Detector 2: dormant-script — shell script with ≤1 inbound reference
/// after widening the grep set to docs/ + .claude/ + Rust mod / SQL include /
/// sibling shell patterns (INFRA-2376). Limited to scripts/coord/ and
/// scripts/dispatch/.
///
/// The `activation_state` filter uses the value populated by
/// `recompute_activation_with_provenance` which now invokes the v2
/// reference collector (`collect_referrers_v2`) — so artifacts referenced
/// only from a .claude/agents/*.md are correctly classified as `dormant`
/// or `referenced` and not flagged here.
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
///
/// INFRA-2378 calibration: skip plists that sit in known template/source
/// directories AND have a sibling installer script — those are intentional
/// templates, not stale-installed daemons. Runtime plists under
/// `~/Library/LaunchAgents/` (which we wouldn't normally have indexed) are
/// still flagged via direct path check.
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
        // INFRA-2378: skip template-source plists with a sibling installer.
        if is_template_plist_with_installer(root, &path) {
            continue;
        }

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

/// INFRA-2378: returns true when a plist lives in a known template/source
/// directory AND has a sibling installer script named `install-<stem>.sh`
/// (or `<stem>-install.sh`) somewhere under scripts/setup/ or scripts/coord/.
fn is_template_plist_with_installer(root: &Path, plist_path: &str) -> bool {
    let is_template_dir = plist_path.starts_with("launchd/")
        || plist_path.starts_with("scripts/setup/launchd-templates/")
        || plist_path.contains("/launchd-fixtures/");
    if !is_template_dir {
        return false;
    }
    let stem = Path::new(plist_path)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    if stem.is_empty() {
        return false;
    }
    // Check for sibling installer candidates.
    let candidates = [
        format!("scripts/setup/install-{}.sh", stem),
        format!("scripts/coord/{}-install.sh", stem),
        format!("scripts/setup/{}-install.sh", stem),
        format!("scripts/coord/install-{}.sh", stem),
    ];
    for c in &candidates {
        if root.join(c).exists() {
            return true;
        }
    }
    false
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
/// `last_modified_at` is > N days ago AND not already classified as
/// removed/superseded in `tech_debt_findings`.
///
/// INFRA-2383 calibration: threshold defaults to 30d (was 90d — which
/// caught 0 artifacts in an active repo). Env-tunable via
/// `CHUMP_INVENTORY_DORMANT_DAYS` for cadence variants. Bounded to
/// substrate paths (src/, scripts/coord/, scripts/dispatch/) to avoid
/// flooding on docs/yaml drift.
fn detect_long_undormant_substrate(conn: &Connection, _root: &Path) -> Result<usize> {
    let days = dormant_days_threshold();
    let cutoff = now_secs() - days * 86400;

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

    // Legacy signal: merged PRs older than the same cutoff with substrate
    // or infra titles (kept for the existing CLI surfacing pattern).
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
                "Substrate PR #{pr_number} merged >{days}d ago — review whether it accreted any users: {title}"
            ),
            evidence_json: None,
        };
        insert_finding(conn, &f)?;
        n += 1;
    }

    Ok(n)
}

/// Detector 8: shadow-duplicate — pairs of artifacts that share a basename
/// prefix AND have ≥70% line-set Jaccard similarity.
///
/// INFRA-2377 calibration: prior bucket-by-8-char-prefix surfaced 1205
/// findings with 0% RP across 20 samples because legitimate sibling
/// families (worker.sh/worker-haiku.sh, pr-rescue-v1.sh/pr-rescue-v2.sh)
/// hit the same bucket. The new detector:
///   1. Buckets by 8-char basename prefix (cheap funnel)
///   2. Skips pairs matching `SHADOW_DUPLICATE_SIBLING_PATTERNS` allowlist
///   3. Computes line-set Jaccard for surviving pairs; flags only ≥0.70
///   4. Names both artifacts explicitly so the operator can compare quickly
fn detect_shadow_duplicates(conn: &Connection, root: &Path) -> Result<usize> {
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
    for (_key, group) in buckets {
        if group.len() < 2 {
            continue;
        }
        // Compute content fingerprints once per file in this bucket.
        let mut fps: Vec<(String, std::collections::HashSet<String>)> = Vec::new();
        for p in &group {
            let full = root.join(p);
            let lines = match fs::read_to_string(&full) {
                Ok(s) => s
                    .lines()
                    .map(|l| l.trim().to_string())
                    .filter(|l| !l.is_empty() && !l.starts_with('#'))
                    .collect::<std::collections::HashSet<String>>(),
                Err(_) => std::collections::HashSet::new(),
            };
            fps.push((p.clone(), lines));
        }
        // Evaluate every unordered pair.
        for i in 0..fps.len() {
            for j in (i + 1)..fps.len() {
                let (p1, ls1) = &fps[i];
                let (p2, ls2) = &fps[j];
                // INFRA-2377 allowlist: skip sibling patterns.
                if is_sibling_pair(p1, p2) {
                    continue;
                }
                let inter: usize = ls1.intersection(ls2).count();
                let uni: usize = ls1.union(ls2).count();
                if uni == 0 {
                    continue;
                }
                let jaccard = inter as f64 / uni as f64;
                if jaccard < 0.70 {
                    continue;
                }
                let pair = vec![p1.clone(), p2.clone()];
                let f = Finding {
                    finding_class: "shadow-duplicate".to_string(),
                    severity: "med".to_string(),
                    artifact_path: Some(p1.clone()),
                    pr_number: None,
                    gap_id: None,
                    detail: format!(
                        "shadow-duplicate pair (jaccard={:.2}): {} <-> {}",
                        jaccard, p1, p2
                    ),
                    evidence_json: Some(serde_json::to_string(&pair).unwrap_or_default()),
                };
                insert_finding(conn, &f)?;
                n += 1;
            }
        }
    }
    Ok(n)
}

/// INFRA-2377: returns true if (p1, p2) matches a known intentional sibling
/// pattern that should NOT be flagged as shadow-duplicate.
fn is_sibling_pair(p1: &str, p2: &str) -> bool {
    for pat in SHADOW_DUPLICATE_SIBLING_PATTERNS {
        if (p1.contains(pat) && !p2.contains(pat)) || (p2.contains(pat) && !p1.contains(pat)) {
            return true;
        }
    }
    false
}

/// Detector 9: event-kind-zero-emit — EVENT_REGISTRY kind has zero
/// occurrences in ambient.jsonl in the last 30d.
///
/// INFRA-2379 calibration: pre-check source has zero emit-sites BEFORE
/// flagging. The prior detector surfaced lots of "kind X is in registry
/// but not in ambient" findings even when source code does emit them — the
/// ambient log just happened to be a fresh window. The new flow:
///   1. For each registry kind, scan source for `"kind":"X"` literals.
///   2. If ≥1 source emit-site exists AND ambient shows zero events,
///      downgrade severity to `info` with `observability_silent` reason
///      (the registry is fine; the log window is empty).
///   3. If zero source emit-sites AND zero ambient events, surface at
///      `low` severity — that's the calibration target (genuine orphan kind).
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
    let mut n = 0usize;
    for kind in kinds {
        let needle = format!("\"kind\":\"{}\"", kind);
        if ambient_content.contains(&needle) {
            continue;
        }
        // INFRA-2379: pre-check source for emit-sites BEFORE flagging.
        let source_has_emit = source_emit_site_exists(root, &kind);
        let (severity, detail) = if source_has_emit {
            (
                "info".to_string(),
                format!(
                    "observability_silent: kind={kind} has source emit-sites but ambient.jsonl shows zero occurrences (log window may be empty)"
                ),
            )
        } else {
            (
                "low".to_string(),
                format!(
                    "EVENT_REGISTRY declares kind={kind} but neither source nor ambient.jsonl show any emit"
                ),
            )
        };
        let f = Finding {
            finding_class: "event-kind-zero-emit".to_string(),
            severity,
            artifact_path: Some("docs/observability/EVENT_REGISTRY.yaml".to_string()),
            pr_number: None,
            gap_id: None,
            detail,
            evidence_json: None,
        };
        insert_finding(conn, &f)?;
        n += 1;
    }
    Ok(n)
}

/// INFRA-2379: scan src/, scripts/, crates/ for at least one literal
/// `"kind":"<kind>"` emit-site. Returns true if found, false otherwise.
///
/// Robust to missing pathspec dirs (fixture repos may not have all three) —
/// queries each existing dir independently and ORs the results.
fn source_emit_site_exists(root: &Path, kind: &str) -> bool {
    let needle = format!("\"kind\":\"{}\"", kind);
    for dir in &["src/", "scripts/", "crates/"] {
        if !root.join(dir).exists() {
            continue;
        }
        let out = Command::new("git")
            .args(["grep", "-l", "-F", "--", &needle, dir])
            .current_dir(root)
            .output();
        if let Ok(o) = out {
            if o.status.success() && !o.stdout.is_empty() {
                return true;
            }
        }
    }
    false
}

/// Detector 10 (INFRA-2382): ghost-gap-reference — PR title references a
/// gap_id but no docs/gaps/<X>.yaml exists in the repo.
///
/// Surfaces the ~541 cases where a PR shipped a now-deleted gap; the gap
/// registry may have been pruned but the PR's link is dangling. The
/// operator can either resurrect the YAML (if the gap was valid) or
/// confirm the PR's commit message can stand alone.
///
/// Bounded to 500 findings per run to avoid flooding the table on a
/// freshly-pruned registry.
fn detect_ghost_gap_references(conn: &Connection, _root: &Path) -> Result<usize> {
    // Query: gap_ids referenced by ≥1 PR title but missing from artifact_index
    // as a docs/gaps/<X>.yaml row.
    let mut rows: Vec<(String, i64, Option<String>)> = Vec::new();
    {
        // SUBSTR is 1-indexed in SQLite. 'docs/gaps/' is 10 chars, so the
        // gap_id begins at position 11. REPLACE then strips '.yaml'.
        let mut stmt = conn.prepare(
            "SELECT gap_id, COUNT(*) AS pr_count,
                    (SELECT GROUP_CONCAT(pr_number) FROM pr_index p2
                     WHERE p2.gap_id = p1.gap_id) AS pr_numbers
             FROM pr_index p1
             WHERE gap_id IS NOT NULL
               AND gap_id NOT IN (
                   SELECT REPLACE(SUBSTR(path, 11), '.yaml', '')
                   FROM artifact_index
                   WHERE path LIKE 'docs/gaps/%.yaml'
               )
             GROUP BY gap_id
             ORDER BY pr_count DESC
             LIMIT 500",
        )?;
        let mapped = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        })?;
        for r in mapped {
            rows.push(r?);
        }
    }
    let mut n = 0usize;
    for (gap_id, pr_count, pr_numbers) in rows {
        // evidence_json holds a JSON array of pr_number ints.
        let pr_list: Vec<i64> = pr_numbers
            .as_deref()
            .map(|s| {
                s.split(',')
                    .filter_map(|x| x.trim().parse::<i64>().ok())
                    .collect()
            })
            .unwrap_or_default();
        let evidence = serde_json::to_string(&pr_list).unwrap_or_else(|_| "[]".to_string());
        let f = Finding {
            finding_class: "ghost-gap-reference".to_string(),
            severity: "med".to_string(),
            artifact_path: None,
            pr_number: pr_list.first().copied(),
            gap_id: Some(gap_id.clone()),
            detail: format!(
                "gap_id {gap_id} appears in {pr_count} PR title(s) but no docs/gaps/{gap_id}.yaml exists on disk"
            ),
            evidence_json: Some(evidence),
        };
        insert_finding(conn, &f)?;
        n += 1;
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

    /// INFRA-2385: PR-number extraction must handle both squash-merge
    /// (`(#NNN)` token) and merge-commit (`Merge pull request #NNN`) shapes.
    #[test]
    #[serial]
    fn extract_pr_number_from_subject_handles_both_shapes() {
        assert_eq!(
            extract_pr_number_from_subject("feat(INFRA-2367): foo (#1234)"),
            Some(1234)
        );
        assert_eq!(
            extract_pr_number_from_subject("Merge pull request #5678 from foo/bar"),
            Some(5678)
        );
        // Prefers trailing token when both are present.
        assert_eq!(
            extract_pr_number_from_subject("Merge pull request #1 from foo (#99)"),
            Some(99)
        );
        assert_eq!(extract_pr_number_from_subject("plain commit no pr"), None);
    }

    /// INFRA-2377: sibling-pair detection must skip well-known intentional
    /// sibling families that share prefixes by design.
    #[test]
    #[serial]
    fn shadow_duplicate_sibling_pair_skipped() {
        // Versioned variants.
        assert!(is_sibling_pair(
            "scripts/coord/pr-rescue-v1.sh",
            "scripts/coord/pr-rescue-v2.sh"
        ));
        // Role-stamped variants.
        assert!(is_sibling_pair(
            "scripts/dispatch/worker.sh",
            "scripts/dispatch/worker-haiku.sh"
        ));
        // Install/uninstall pair.
        assert!(is_sibling_pair(
            "scripts/setup/install-fleet.sh",
            "scripts/setup/uninstall-fleet.sh"
        ));
        // True duplicates (no sibling-marker on either side) → NOT siblings.
        assert!(!is_sibling_pair(
            "scripts/coord/foo-loop.sh",
            "scripts/coord/foo-loop-copy.sh"
        ));
    }

    /// INFRA-2383: env-var override for dormant cutoff.
    #[test]
    #[serial]
    fn dormant_days_threshold_reads_env_var() {
        std::env::set_var("CHUMP_INVENTORY_DORMANT_DAYS", "60");
        assert_eq!(dormant_days_threshold(), 60);
        std::env::set_var("CHUMP_INVENTORY_DORMANT_DAYS", "0");
        // Zero or invalid falls back to default 30.
        assert_eq!(dormant_days_threshold(), 30);
        std::env::remove_var("CHUMP_INVENTORY_DORMANT_DAYS");
        assert_eq!(dormant_days_threshold(), 30);
    }

    /// INFRA-2382: ghost-gap-reference must surface PRs whose gap_id has
    /// no docs/gaps/<X>.yaml row in artifact_index.
    #[test]
    #[serial]
    fn ghost_gap_reference_detector_surfaces_missing_yaml() {
        let (_tmp, conn) = setup_test_db();
        // Seed pr_index with 2 PRs referencing INFRA-9999 (no YAML).
        conn.execute(
            "INSERT INTO pr_index (pr_number, title, state, created_at, gap_id, last_synced_at)
             VALUES (1001, 'feat(INFRA-9999): ghost', 'MERGED', 0, 'INFRA-9999', 0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO pr_index (pr_number, title, state, created_at, gap_id, last_synced_at)
             VALUES (1002, 'feat(INFRA-9999): ghost again', 'MERGED', 0, 'INFRA-9999', 0)",
            [],
        )
        .unwrap();
        // Seed an unrelated PR with gap_id whose YAML DOES exist.
        conn.execute(
            "INSERT INTO pr_index (pr_number, title, state, created_at, gap_id, last_synced_at)
             VALUES (1003, 'feat(INFRA-1000): real', 'MERGED', 0, 'INFRA-1000', 0)",
            [],
        )
        .unwrap();
        // Insert the matching artifact row for INFRA-1000 (real gap on disk).
        conn.execute(
            "INSERT INTO artifact_index (path, class, size_bytes, first_seen_at,
                                          last_modified_at, activation_state, last_synced_at)
             VALUES ('docs/gaps/INFRA-1000.yaml', 'yaml', 0, 0, 0, 'referenced', 0)",
            [],
        )
        .unwrap();

        let n = detect_ghost_gap_references(&conn, &PathBuf::from(".")).unwrap();
        assert_eq!(n, 1, "exactly 1 ghost-gap finding (INFRA-9999)");
        let row: (String, i64) = conn
            .query_row(
                "SELECT gap_id, pr_number FROM tech_debt_findings
                 WHERE finding_class='ghost-gap-reference'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(row.0, "INFRA-9999");
        // pr_number is the first in the comma-joined list (ordered by SQL).
        assert!(row.1 == 1001 || row.1 == 1002);
    }

    /// INFRA-2382: ghost-gap-reference must skip PRs whose gap_id has a
    /// matching docs/gaps/<X>.yaml row in artifact_index.
    #[test]
    #[serial]
    fn ghost_gap_reference_detector_skips_resolved_gaps() {
        let (_tmp, conn) = setup_test_db();
        conn.execute(
            "INSERT INTO pr_index (pr_number, title, state, created_at, gap_id, last_synced_at)
             VALUES (1, 'feat(INFRA-1): ok', 'MERGED', 0, 'INFRA-1', 0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO artifact_index (path, class, size_bytes, first_seen_at,
                                          last_modified_at, activation_state, last_synced_at)
             VALUES ('docs/gaps/INFRA-1.yaml', 'yaml', 0, 0, 0, 'referenced', 0)",
            [],
        )
        .unwrap();
        let n = detect_ghost_gap_references(&conn, &PathBuf::from(".")).unwrap();
        assert_eq!(n, 0);
    }

    /// Migration must seed the 10th detector class for ghost-gap-reference.
    #[test]
    #[serial]
    fn migration_seeds_ten_detector_classes() {
        let (_tmp, conn) = setup_test_db();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM finding_class_tiers", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 10);
        let exists: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM finding_class_tiers WHERE finding_class='ghost-gap-reference'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(exists, 1);
    }
}
