//! INFRA-8061: the UNIVERSAL gap-intake filer — one filing path every agent
//! location uses (Mac, cuphead, cloud ephemeral agents, and a stranger running
//! their own chump).
//!
//! ## Why
//!
//! Cloud/ephemeral agents produce real findings but historically could not file
//! them: they don't know `holler`, can't SSH cuphead, the holler drain was dead,
//! and the tailnet ACL only granted them NATS (`:4222`), not the gap API. The
//! 2026-10-03 re-point of `scripts/first-mate/file-finding.mjs` to `chump gap
//! reserve` over Tailscale SSH was Mac-only (it shells `tailscale ssh ...`).
//!
//! This module is the portable replacement: a finding becomes a canonical gap
//! by POSTing to a configured gap endpoint — `CHUMP_GAP_URL` — which defaults to
//! the deployment's own fleet-server `POST /api/gap`. That endpoint is the
//! canonical gap-write (`crates/chump-fleet-server/src/gap_write.rs`, INFRA-3689),
//! bat-phone-bearer-authenticated via `CHUMP_BATPHONE_TOKEN` — the same wire
//! schema `holler-to-chump.mjs --apply` and `src/gap_route.rs` already use. We
//! reuse [`crate::gap_route::route_gap_mutation_to_url`] verbatim; there is no
//! second write path to audit.
//!
//! ## Durability
//!
//! If the endpoint is down/unreachable, the finding is appended to a durable
//! LOCAL spool file ([`spool_path`]) and retried on the next invocation — nothing
//! is lost even when the store is down. The spool is a plain JSONL file owned by
//! the filer (NOT a shared Supabase inbox and NOT a drain organ).
//!
//! ## Portability
//!
//! A stranger points `CHUMP_GAP_URL` at their own chump fleet-server; there is no
//! dependency on Jeff's Supabase, no tailscale, and no SSH. The bearer token is
//! whatever that deployment uses for `/api/gap`.

use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::gap_route::{route_gap_mutation_to_url, GapMutationBody};

/// Env var: the FULL URL of the gap-write endpoint, e.g.
/// `http://127.0.0.1:7070/api/gap`. Unset falls back to `CHUMP_GAP_SERVER`
/// (a base URL) + `/api/gap`, then to the localhost default.
pub const GAP_URL_ENV: &str = "CHUMP_GAP_URL";
/// Env var: override the durable spool file path. Unset uses
/// `$HOME/.local/state/chump/gap-spool.jsonl`.
pub const GAP_SPOOL_ENV: &str = "CHUMP_GAP_SPOOL";
/// Localhost default endpoint when neither `CHUMP_GAP_URL` nor
/// `CHUMP_GAP_SERVER` is set — the deployment's own fleet-server.
pub const DEFAULT_GAP_URL: &str = "http://127.0.0.1:7070/api/gap";

/// A finding as any agent files it. Field-compatible with
/// `scripts/first-mate/file-finding.mjs`'s `finding.json` so that script can
/// re-pivot onto this path without changing its CLI contract.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Finding {
    /// Real repo slug when possible, e.g. `"olive"` or `"chump"`.
    pub project: String,
    /// `owner/repo` fix path, or `None` for no repo.
    #[serde(default)]
    pub repo: Option<String>,
    pub title: String,
    #[serde(default)]
    pub body: String,
    /// Acceptance criteria (required unless parked).
    #[serde(default)]
    pub acceptance: Vec<String>,
    /// `P0`..`P3`; anything else (or unset) becomes `P2`.
    #[serde(default)]
    pub priority: Option<String>,
    /// Override the gap domain; otherwise derived from `project`.
    #[serde(default)]
    pub domain: Option<String>,
    /// Override the external-repo tag; otherwise derived from `repo`.
    #[serde(default)]
    pub external_repo: Option<String>,
    /// Set => recorded locally by the caller, never filed as a gap.
    #[serde(default)]
    pub parked: Option<String>,
}

/// Resolve the gap-write endpoint URL from the environment.
///
/// Precedence: `CHUMP_GAP_URL` (full URL) > `CHUMP_GAP_SERVER` (base URL) +
/// `/api/gap` > [`DEFAULT_GAP_URL`]. Kept pure (takes the two env values) so
/// the precedence is unit-testable without touching process environment.
pub fn resolve_gap_url(gap_url: Option<&str>, gap_server: Option<&str>) -> String {
    if let Some(u) = gap_url.map(str::trim).filter(|s| !s.is_empty()) {
        return u.to_string();
    }
    if let Some(base) = gap_server.map(str::trim).filter(|s| !s.is_empty()) {
        return format!("{}/api/gap", base.trim_end_matches('/'));
    }
    DEFAULT_GAP_URL.to_string()
}

/// Resolve the endpoint URL from the real process environment.
pub fn resolve_gap_url_from_env() -> String {
    resolve_gap_url(
        std::env::var(GAP_URL_ENV).ok().as_deref(),
        std::env::var(crate::gap_route::GAP_SERVER_ENV)
            .ok()
            .as_deref(),
    )
}

/// Default spool path: `$HOME/.local/state/chump/gap-spool.jsonl`, overridable
/// via `CHUMP_GAP_SPOOL`.
pub fn spool_path() -> PathBuf {
    if let Ok(p) = std::env::var(GAP_SPOOL_ENV) {
        if !p.trim().is_empty() {
            return PathBuf::from(p);
        }
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    home.join(".local/state/chump/gap-spool.jsonl")
}

/// Normalize a priority to `P0`..`P3`, defaulting to `P2`.
fn resolve_priority(p: Option<&str>) -> String {
    match p.map(str::trim) {
        Some(v) if matches!(v, "P0" | "P1" | "P2" | "P3") => v.to_string(),
        _ => "P2".to_string(),
    }
}

/// Domain for a finding: explicit `domain`, else `INFRA` for the chump repo
/// itself and `PRODUCT` for everything else (mirrors file-finding.mjs).
fn resolve_domain(f: &Finding) -> String {
    if let Some(d) = f.domain.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        return d.to_string();
    }
    if f.project == "chump" {
        "INFRA".to_string()
    } else {
        "PRODUCT".to_string()
    }
}

/// External-repo tag: explicit `external_repo`, else `repo` when the finding is
/// against some repo other than chump itself.
fn resolve_external_repo(f: &Finding) -> Option<String> {
    if let Some(e) = f
        .external_repo
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        return Some(e.to_string());
    }
    match f.repo.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        Some(r) if f.project != "chump" => Some(r.to_string()),
        _ => None,
    }
}

/// The `reserve` op body for a finding (pure; testable without a server).
pub fn reserve_body(f: &Finding) -> GapMutationBody {
    GapMutationBody {
        op: "reserve".into(),
        domain: Some(resolve_domain(f)),
        title: Some(f.title.clone()),
        priority: Some(resolve_priority(f.priority.as_deref())),
        external_repo: resolve_external_repo(f),
        ..Default::default()
    }
}

/// The follow-up `set` op body that fills description + AC and opens the gap
/// the `reserve` returned (pure; testable without a server).
pub fn set_body(f: &Finding, gap_id: &str) -> GapMutationBody {
    GapMutationBody {
        op: "set".into(),
        gap_id: Some(gap_id.to_string()),
        description: Some(f.body.clone()),
        acceptance_criteria: (!f.acceptance.is_empty()).then(|| f.acceptance.clone()),
        status: Some("open".into()),
        ..Default::default()
    }
}

/// POST one finding to `url`: `reserve`, then a follow-up `set` that fills the
/// description/AC and opens the gap. Returns the canonical gap id on success.
/// Either POST failing surfaces as `Err` (the caller spools and retries).
pub async fn file_finding(url: &str, token: &str, f: &Finding) -> anyhow::Result<String> {
    let reserved = route_gap_mutation_to_url(url, token, &reserve_body(f)).await?;
    let gap_id = reserved.gap_id;
    if gap_id.trim().is_empty() {
        anyhow::bail!("reserve returned an empty gap id");
    }
    route_gap_mutation_to_url(url, token, &set_body(f, &gap_id)).await?;
    Ok(gap_id)
}

/// Append one finding to the durable spool (creating parent dirs as needed).
pub fn append_spool(spool: &Path, f: &Finding) -> std::io::Result<()> {
    if let Some(dir) = spool.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(spool)?;
    let line = serde_json::to_string(f).map_err(std::io::Error::other)?;
    writeln!(file, "{line}")
}

/// Read all spooled findings. Missing file => empty. Unparseable lines are
/// skipped (a corrupt line never wedges the whole spool).
pub fn read_spool(spool: &Path) -> Vec<Finding> {
    let file = match std::fs::File::open(spool) {
        Ok(f) => f,
        Err(_) => return Vec::new(),
    };
    std::io::BufReader::new(file)
        .lines()
        .map_while(Result::ok)
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str::<Finding>(&l).ok())
        .collect()
}

/// Atomically rewrite the spool to exactly `remaining` (empty slice truncates).
pub fn rewrite_spool(spool: &Path, remaining: &[Finding]) -> std::io::Result<()> {
    if let Some(dir) = spool.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = spool.with_extension("jsonl.tmp");
    {
        let mut file = std::fs::File::create(&tmp)?;
        for f in remaining {
            let line = serde_json::to_string(f).map_err(std::io::Error::other)?;
            writeln!(file, "{line}")?;
        }
    }
    std::fs::rename(&tmp, spool)
}

/// Outcome of attempting to file a finding.
#[derive(Debug)]
pub enum FileOutcome {
    /// Filed as a canonical gap.
    Filed(String),
    /// Endpoint unreachable/failed; the finding was spooled for retry.
    Spooled(String),
}

/// Try to file `f`; on any error, append it to `spool` so it is retried on the
/// next invocation. Never loses the finding.
pub async fn file_or_spool(url: &str, token: &str, spool: &Path, f: &Finding) -> FileOutcome {
    match file_finding(url, token, f).await {
        Ok(gap_id) => FileOutcome::Filed(gap_id),
        Err(e) => {
            let reason = e.to_string();
            if let Err(spool_err) = append_spool(spool, f) {
                // Could not even spool — surface both failures loudly.
                return FileOutcome::Spooled(format!(
                    "{reason}; AND spool write failed: {spool_err}"
                ));
            }
            FileOutcome::Spooled(reason)
        }
    }
}

/// Retry every spooled finding against `url`. Returns `(filed, remaining)`.
/// Findings that still fail are kept in the spool for the next drain.
pub async fn drain_spool(url: &str, token: &str, spool: &Path) -> (usize, usize) {
    let items = read_spool(spool);
    if items.is_empty() {
        return (0, 0);
    }
    let mut remaining = Vec::new();
    let mut filed = 0usize;
    for f in items {
        match file_finding(url, token, &f).await {
            Ok(_) => filed += 1,
            Err(_) => remaining.push(f),
        }
    }
    // Best-effort rewrite; if it fails the next drain simply retries the lot.
    let _ = rewrite_spool(spool, &remaining);
    let remaining_n = remaining.len();
    (filed, remaining_n)
}

/// `chump gap file <finding.json> [--drain] [--dry-run]`.
///
/// Reads a finding (JSON file), drains any previously-spooled findings first
/// (retry), then files the new finding (spooling it on failure). `--drain`
/// only flushes the spool. Prints the canonical gap id on success.
pub async fn run(args: &[String]) -> anyhow::Result<()> {
    let drain_only = args.iter().any(|a| a == "--drain");
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let file_arg = args
        .iter()
        .skip(3) // ["chump", "gap", "file", ...]
        .find(|a| !a.starts_with("--"))
        .cloned();

    let url = resolve_gap_url_from_env();
    let token = std::env::var(crate::gap_route::BATPHONE_TOKEN_ENV).unwrap_or_default();
    let spool = spool_path();

    if dry_run {
        let n = read_spool(&spool).len();
        println!(
            "[dry-run] endpoint={url} spool={} ({n} spooled)",
            spool.display()
        );
        if let Some(path) = &file_arg {
            let f = load_finding(path)?;
            if f.parked.is_some() {
                println!("[dry-run] parked, would NOT file: {}", f.title);
            } else {
                println!(
                    "[dry-run] would POST reserve+set for {} gap: {}",
                    resolve_domain(&f),
                    f.title
                );
            }
        }
        return Ok(());
    }

    // Retry the backlog first so a recovered endpoint catches up.
    if !read_spool(&spool).is_empty() {
        let (filed, remaining) = drain_spool(&url, &token, &spool).await;
        if filed > 0 || remaining > 0 {
            eprintln!("spool drain: filed {filed}, {remaining} still pending");
        }
    }

    if drain_only {
        return Ok(());
    }

    let path = file_arg.ok_or_else(|| {
        anyhow::anyhow!("usage: chump gap file <finding.json> [--drain] [--dry-run]")
    })?;
    let f = load_finding(&path)?;

    if let Some(reason) = &f.parked {
        println!("parked, not filed: {reason}");
        return Ok(());
    }
    if f.acceptance.is_empty() {
        anyhow::bail!("a finding that should become a gap needs non-empty \"acceptance\"");
    }

    match file_or_spool(&url, &token, &spool, &f).await {
        FileOutcome::Filed(gap_id) => {
            println!("{gap_id}");
            Ok(())
        }
        FileOutcome::Spooled(reason) => {
            eprintln!(
                "endpoint unreachable ({reason}); spooled to {} — retries on next invocation",
                spool.display()
            );
            // Spooling is a success for durability: the finding is not lost.
            Ok(())
        }
    }
}

fn load_finding(path: &str) -> anyhow::Result<Finding> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| anyhow::anyhow!("cannot read finding {path}: {e}"))?;
    serde_json::from_str(&raw).map_err(|e| anyhow::anyhow!("invalid finding JSON in {path}: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use wiremock::matchers::{header, method, path as path_matcher};
    use wiremock::{Mock, MockServer, Request, ResponseTemplate};

    fn finding() -> Finding {
        Finding {
            project: "olive".into(),
            repo: Some("repairman29/olive".into()),
            title: "Checkout 500s on empty cart".into(),
            body: "Repro: POST /checkout with no items -> 500.".into(),
            acceptance: vec!["empty cart returns 400 not 500".into()],
            priority: Some("P1".into()),
            domain: None,
            external_repo: None,
            parked: None,
        }
    }

    #[test]
    fn url_precedence() {
        assert_eq!(
            resolve_gap_url(Some("http://h:9/api/gap"), Some("http://b:7070")),
            "http://h:9/api/gap"
        );
        assert_eq!(
            resolve_gap_url(None, Some("http://b:7070/")),
            "http://b:7070/api/gap"
        );
        assert_eq!(resolve_gap_url(None, None), DEFAULT_GAP_URL);
        assert_eq!(
            resolve_gap_url(Some("  "), Some("http://b:7070")),
            "http://b:7070/api/gap"
        );
    }

    #[test]
    fn bodies_map_finding_fields() {
        let f = finding();
        let rb = reserve_body(&f);
        assert_eq!(rb.op, "reserve");
        assert_eq!(rb.domain.as_deref(), Some("PRODUCT")); // non-chump project
        assert_eq!(rb.title.as_deref(), Some("Checkout 500s on empty cart"));
        assert_eq!(rb.priority.as_deref(), Some("P1"));
        assert_eq!(rb.external_repo.as_deref(), Some("repairman29/olive"));

        let sb = set_body(&f, "PRODUCT-9001");
        assert_eq!(sb.op, "set");
        assert_eq!(sb.gap_id.as_deref(), Some("PRODUCT-9001"));
        assert_eq!(sb.status.as_deref(), Some("open"));
        assert_eq!(
            sb.acceptance_criteria.as_deref(),
            Some(&["empty cart returns 400 not 500".to_string()][..])
        );

        // chump project -> INFRA domain, no external repo.
        let mut cf = finding();
        cf.project = "chump".into();
        cf.repo = Some("repairman29/chump".into());
        let rb = reserve_body(&cf);
        assert_eq!(rb.domain.as_deref(), Some("INFRA"));
        assert_eq!(rb.external_repo, None);

        // junk/absent priority -> P2.
        let mut pf = finding();
        pf.priority = Some("urgent".into());
        assert_eq!(reserve_body(&pf).priority.as_deref(), Some("P2"));
    }

    #[test]
    fn spool_round_trip() {
        let dir = tempdir().unwrap();
        let spool = dir.path().join("sub/gap-spool.jsonl");
        assert!(read_spool(&spool).is_empty());
        append_spool(&spool, &finding()).unwrap();
        let mut second = finding();
        second.title = "Second".into();
        append_spool(&spool, &second).unwrap();
        let read = read_spool(&spool);
        assert_eq!(read.len(), 2);
        assert_eq!(read[1].title, "Second");
        rewrite_spool(&spool, &read[1..]).unwrap();
        let after = read_spool(&spool);
        assert_eq!(after.len(), 1);
        assert_eq!(after[0].title, "Second");
    }

    /// End-to-end at the wire: a finding becomes a canonical gap via POST to
    /// CHUMP_GAP_URL — reserve then set, both bearer-authed.
    #[tokio::test]
    async fn file_finding_posts_reserve_then_set() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_matcher("/api/gap"))
            .and(header("authorization", "Bearer tok123"))
            .respond_with(|req: &Request| {
                let body: serde_json::Value = serde_json::from_slice(&req.body).unwrap();
                let op = body["op"].as_str().unwrap_or("");
                // reserve mints the id; set echoes the id it was given.
                let gap_id = if op == "reserve" {
                    "PRODUCT-9001".to_string()
                } else {
                    body["gap_id"].as_str().unwrap_or("").to_string()
                };
                ResponseTemplate::new(200).set_body_json(serde_json::json!({
                    "gap_id": gap_id, "op": op, "status": "ok", "detail": "done"
                }))
            })
            .expect(2) // exactly reserve + set
            .mount(&server)
            .await;

        let url = format!("{}/api/gap", server.uri());
        let gid = file_finding(&url, "tok123", &finding()).await.unwrap();
        assert_eq!(gid, "PRODUCT-9001");
    }

    /// Spool-and-retry: a down endpoint spools the finding; a later drain
    /// against a healthy endpoint files it and empties the spool.
    #[tokio::test]
    async fn spools_on_failure_then_drains_on_retry() {
        let dir = tempdir().unwrap();
        let spool = dir.path().join("gap-spool.jsonl");

        // 1) endpoint down (500) -> file_or_spool spools, loses nothing.
        let down = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&down)
            .await;
        let down_url = format!("{}/api/gap", down.uri());
        let outcome = file_or_spool(&down_url, "tok", &spool, &finding()).await;
        assert!(matches!(outcome, FileOutcome::Spooled(_)));
        assert_eq!(read_spool(&spool).len(), 1, "finding must be spooled");

        // 2) endpoint healthy -> drain files it and clears the spool.
        let up = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_matcher("/api/gap"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "gap_id": "PRODUCT-1", "op": "x", "status": "ok", "detail": "d"
            })))
            .mount(&up)
            .await;
        let up_url = format!("{}/api/gap", up.uri());
        let (filed, remaining) = drain_spool(&up_url, "tok", &spool).await;
        assert_eq!(filed, 1);
        assert_eq!(remaining, 0);
        assert!(
            read_spool(&spool).is_empty(),
            "spool must be empty after drain"
        );
    }
}
