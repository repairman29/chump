//! `chump onboard <repo-url-or-path>` — first-touch external-repo scanner.
//!
//! Flow:
//! 1. Clone (shallow, depth 1) to `~/.chump/external/<owner>/<repo>/clone/`
//!    if a URL is given; otherwise use the path as-is.
//! 2. Read intent docs: README.md, CLAUDE.md, AGENTS.md, ideas/TODO.md,
//!    IMPLEMENTATION.md, ROADMAP.md (and docs/ROADMAP.md), last 20 commit
//!    messages, and the top-level package manifest.
//! 3. Call the provider cascade with a discovery prompt requesting 5–10
//!    next-step gap proposals in JSON shape.
//! 4. Surface as a markdown table to stdout; `--apply` runs `chump gap
//!    reserve` for each proposed gap, tagging `skills_required:
//!    external_repo:<owner>/<repo>`.
//! 5. Persist the scan result to
//!    `~/.chump/external/<owner>/<repo>/scans/onboard-scan-<ts>.json`
//!    per the INFRA-2116 schema.
//!
//! INFRA-2108 (META-123 Wave 2)

use anyhow::{anyhow, bail, Context, Result};
use chrono::Utc;
use chump_handoff::external_repo_schema::{
    save_scan, validate_external_repo_tag, Confidence, Effort, InputRead, OnboardScan, Priority,
    ProposedGap, SourceOfEvidence,
};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

// ── Constants ─────────────────────────────────────────────────────────────

const TOOL_VERSION: &str = env!("CARGO_PKG_VERSION");

// ── Public entry point ────────────────────────────────────────────────────

/// `chump onboard` subcommand. `args` is everything *after* `onboard`.
pub fn run(args: &[String]) -> i32 {
    match run_inner(args) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("chump onboard: {e:#}");
            1
        }
    }
}

// ── CLI parsing ───────────────────────────────────────────────────────────

struct Opts {
    repo_url_or_path: String,
    clone_to: Option<PathBuf>,
    max_gaps: usize,
    apply: bool,
}

fn parse_args(args: &[String]) -> Result<Opts> {
    let mut repo_url_or_path: Option<String> = None;
    let mut clone_to: Option<PathBuf> = None;
    let mut max_gaps: usize = 10;
    let mut apply = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--help" | "-h" => {
                print_usage();
                std::process::exit(0);
            }
            "--apply" => apply = true,
            "--clone-to" => {
                i += 1;
                let v = args
                    .get(i)
                    .ok_or_else(|| anyhow!("--clone-to requires a value"))?;
                clone_to = Some(PathBuf::from(v));
            }
            "--max-gaps" => {
                i += 1;
                let v = args
                    .get(i)
                    .ok_or_else(|| anyhow!("--max-gaps requires a value"))?;
                max_gaps = v.parse().context("--max-gaps must be a positive integer")?;
            }
            a if a.starts_with("--clone-to=") => {
                clone_to = Some(PathBuf::from(a.trim_start_matches("--clone-to=")));
            }
            a if a.starts_with("--max-gaps=") => {
                max_gaps = a
                    .trim_start_matches("--max-gaps=")
                    .parse()
                    .context("--max-gaps must be a positive integer")?;
            }
            a if !a.starts_with('-') => {
                if repo_url_or_path.is_some() {
                    bail!("unexpected extra argument: {a}");
                }
                repo_url_or_path = Some(a.to_string());
            }
            a => bail!("unknown flag: {a}"),
        }
        i += 1;
    }
    Ok(Opts {
        repo_url_or_path: repo_url_or_path.ok_or_else(|| {
            anyhow!("Usage: chump onboard <repo-url-or-path> [--clone-to PATH] [--max-gaps N] [--apply]")
        })?,
        clone_to,
        max_gaps,
        apply,
    })
}

fn print_usage() {
    println!("Usage: chump onboard <repo-url-or-path> [options]");
    println!();
    println!("First-touch scanner: clones an external repo, reads its intent docs,");
    println!("proposes 5–10 next-step gaps via the provider cascade, and surfaces them");
    println!("as a markdown table. With --apply, reserves each gap in the local registry.");
    println!();
    println!("Options:");
    println!("  --clone-to PATH   Clone destination (default: ~/.chump/external/<owner>/<repo>/)");
    println!("  --max-gaps N      Maximum proposed gaps (default: 10)");
    println!("  --apply           Reserve each proposed gap with chump gap reserve");
}

// ── Core logic ────────────────────────────────────────────────────────────

fn run_inner(args: &[String]) -> Result<()> {
    let opts = parse_args(args)?;
    let repo_url_or_path = opts.repo_url_or_path.trim().to_string();

    // Determine if input is a URL or a local path
    let is_url = repo_url_or_path.starts_with("https://")
        || repo_url_or_path.starts_with("http://")
        || repo_url_or_path.starts_with("git@")
        || repo_url_or_path.starts_with("ssh://");

    // Derive owner/repo slug
    let (owner_repo, clone_root) = if is_url {
        let slug = extract_owner_repo(&repo_url_or_path)?;
        let dest = match opts.clone_to {
            Some(ref p) => p.clone(),
            None => external_repo_dir(&slug),
        };
        (slug, dest)
    } else {
        let path = PathBuf::from(&repo_url_or_path);
        let slug = path
            .file_name()
            .and_then(|n| n.to_str())
            .map(|n| format!("local/{n}"))
            .unwrap_or_else(|| "local/repo".to_string());
        let dest = match opts.clone_to {
            Some(ref p) => p.clone(),
            None => path.clone(),
        };
        (slug, dest)
    };

    // Validate tag shape (catches uppercase slugs early)
    let tag = format!(
        "external_repo:{}",
        owner_repo.to_lowercase().replace(' ', "-")
    );
    validate_external_repo_tag(&tag)
        .map_err(|e| anyhow!("invalid external-repo tag '{tag}': {e}"))?;

    // Clone if URL
    let clone_dir = if is_url {
        let git_dir = clone_root.join("clone");
        if !git_dir.join(".git").exists() {
            shallow_clone(&repo_url_or_path, &git_dir)?;
        } else {
            eprintln!(
                "chump onboard: reusing existing clone at {}",
                git_dir.display()
            );
        }
        git_dir
    } else {
        clone_root.clone()
    };

    eprintln!("chump onboard: scanning {} ...", owner_repo);

    // Read intent inputs
    let mut inputs_read: Vec<InputRead> = Vec::new();
    let mut context_parts: Vec<String> = Vec::new();

    let intent_files = [
        "README.md",
        "CLAUDE.md",
        "AGENTS.md",
        "ideas/TODO.md",
        "IMPLEMENTATION.md",
        "ROADMAP.md",
        "docs/ROADMAP.md",
    ];
    for rel in &intent_files {
        if let Some((content, sha)) = read_file_with_sha(&clone_dir, rel) {
            let preview = truncate_chars(&content, 3000);
            context_parts.push(format!("### {rel}\n{preview}"));
            inputs_read.push(InputRead {
                path: rel.to_string(),
                sha256: sha,
                summary: first_line(&content),
            });
        }
    }

    // Last 20 commit messages
    let commits = git_log(&clone_dir, 20);
    if !commits.is_empty() {
        context_parts.push(format!("### Last 20 commit messages\n{commits}"));
    }

    // Open issues + PRs (via gh CLI; tolerant of missing/unavailable)
    let gh_context = fetch_gh_context(&owner_repo);
    if !gh_context.is_empty() {
        context_parts.push(format!("### Open issues and PRs\n{gh_context}"));
        inputs_read.push(InputRead {
            path: "github:issues+prs".to_string(),
            sha256: hex_sha256(gh_context.as_bytes()),
            summary: "Open GitHub issues and PRs".to_string(),
        });
    }

    // Package manifest (first match wins)
    let manifests = ["package.json", "Cargo.toml", "pyproject.toml", "go.mod"];
    for m in &manifests {
        if let Some((content, sha)) = read_file_with_sha(&clone_dir, m) {
            let preview = truncate_chars(&content, 1500);
            context_parts.push(format!("### {m} (tech stack)\n```\n{preview}\n```"));
            inputs_read.push(InputRead {
                path: m.to_string(),
                sha256: sha,
                summary: format!("Package manifest ({m})"),
            });
            break;
        }
    }

    if context_parts.is_empty() {
        bail!(
            "no readable intent documents found in {}",
            clone_dir.display()
        );
    }

    let max_g = opts.max_gaps;
    let context_body = context_parts.join("\n\n");

    // ── LLM prompt ────────────────────────────────────────────────────────

    let system_prompt = format!(
        "You are a senior software project manager. \
        Your job is to read an external repo's intent documents and propose {max_g} \
        concrete next-step gaps for a human operator using the Chump agent system. \
        Each gap must follow Chump conventions: \
        - id: leave blank (will be assigned) \
        - domain: one of EFFECTIVE, INFRA, DOC, CREDIBLE, RESILIENT \
        - title: pillar-prefix + short imperative (e.g. 'EFFECTIVE: add streaming support') \
        - priority: P0/P1/P2/P3 \
        - effort: xs/s/m/l \
        - confidence: high/med/low — how confident you are this gap is real \
        - source: which input file/section justified this (1 sentence) \
        - ac_draft: 2–3 testable acceptance criteria (bullet strings) \
        Output ONLY a JSON array of objects with exactly these keys: \
        title, domain, priority, effort, confidence, source, ac_draft (array of strings). \
        No prose outside the JSON array."
    );

    let user_msg = format!(
        "Repo: {owner_repo}\n\n\
        Intent documents and signals:\n\n\
        {context_body}\n\n\
        Propose {max_g} next-step gaps for this repo."
    );

    eprintln!("chump onboard: calling provider cascade ({max_g} gaps requested)...");

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("failed to build tokio runtime")?;

    let raw_text = rt.block_on(async {
        let provider = crate::provider_cascade::build_provider();
        let messages = vec![axonerai::provider::Message {
            role: "user".into(),
            content: user_msg,
        }];
        let resp = provider
            .complete(messages, None, Some(4096), Some(system_prompt))
            .await?;
        Ok::<String, anyhow::Error>(resp.text.unwrap_or_default())
    })?;

    // ── Parse LLM JSON response ───────────────────────────────────────────

    let json_start = raw_text.find('[').unwrap_or(0);
    let json_end = raw_text.rfind(']').map(|i| i + 1).unwrap_or(raw_text.len());
    let json_slice = &raw_text[json_start..json_end];

    #[derive(Debug, serde::Deserialize)]
    struct LlmGap {
        title: String,
        domain: String,
        priority: String,
        effort: String,
        confidence: String,
        source: String,
        #[serde(default)]
        ac_draft: Vec<String>,
    }

    let llm_gaps: Vec<LlmGap> = serde_json::from_str(json_slice).map_err(|e| {
        anyhow!(
            "failed to parse LLM response as JSON: {e}\nRaw (first 500): {}",
            &raw_text[..raw_text.len().min(500)]
        )
    })?;

    if llm_gaps.is_empty() {
        bail!("LLM returned no gap proposals");
    }

    // ── Convert to schema types ───────────────────────────────────────────

    let proposed_gaps: Vec<ProposedGap> = llm_gaps
        .iter()
        .map(|g| ProposedGap {
            title: g.title.clone(),
            domain: g.domain.clone(),
            priority: parse_priority(&g.priority),
            effort: parse_effort(&g.effort),
            confidence: parse_confidence(&g.confidence),
            source_of_evidence: SourceOfEvidence {
                input_path: extract_source_path(&g.source),
                section: g.source.clone(),
                excerpt: g.source.clone(),
            },
            acceptance_criteria_draft: g.ac_draft.clone(),
        })
        .collect();

    // ── Markdown table output ─────────────────────────────────────────────

    println!("\n## Proposed gaps for `{owner_repo}`\n");
    println!("| # | Domain | Priority | Effort | Confidence | Title |");
    println!("|---|--------|----------|--------|------------|-------|");
    for (i, g) in llm_gaps.iter().enumerate() {
        println!(
            "| {} | {} | {} | {} | {} | {} |",
            i + 1,
            g.domain,
            g.priority,
            g.effort,
            g.confidence,
            g.title
        );
    }
    println!();
    println!("**Source evidence:**");
    for (i, g) in llm_gaps.iter().enumerate() {
        println!("{}. {}", i + 1, g.source);
        if !g.ac_draft.is_empty() {
            for ac in &g.ac_draft {
                println!("   - {ac}");
            }
        }
    }

    // ── Persist scan result ───────────────────────────────────────────────

    let scan_ts = Utc::now();
    let scan = OnboardScan {
        scan_timestamp: scan_ts,
        external_repo: owner_repo.clone(),
        tool_version: TOOL_VERSION.to_string(),
        inputs_read: inputs_read.clone(),
        proposed_gaps,
    };

    // Repo dir for scan output: always under ~/.chump/external/<slug>/
    // even if the user passed a local path (so scans accumulate in one place).
    let repo_dir = external_repo_dir(&owner_repo);
    save_scan(&repo_dir, &scan).context("failed to persist scan JSON")?;
    eprintln!(
        "chump onboard: scan persisted to {}",
        chump_handoff::external_repo_schema::scan_path(&repo_dir, &scan_ts).display()
    );

    // ── --apply: reserve gaps ─────────────────────────────────────────────

    if opts.apply {
        println!("\n## Reserving gaps (--apply mode)...\n");
        let tag_value = format!(
            "external_repo:{}",
            owner_repo.to_lowercase().replace(' ', "-")
        );
        for g in &llm_gaps {
            let ac_str = g.ac_draft.join("; ");
            let mut cmd = Command::new("chump");
            cmd.args([
                "gap",
                "reserve",
                "--domain",
                &g.domain,
                "--title",
                &g.title,
                "--priority",
                &g.priority,
                "--effort",
                &g.effort,
                "--skills-required",
                &tag_value,
            ]);
            if !ac_str.is_empty() {
                cmd.args(["--ac", &ac_str]);
            }
            match cmd.status() {
                Ok(s) if s.success() => println!("  reserved: {}", g.title),
                Ok(s) => eprintln!("  warn: reserve exited {} for: {}", s, g.title),
                Err(e) => eprintln!("  warn: could not run chump gap reserve: {e}"),
            }
        }
        println!();
        println!(
            "Gaps tagged `{tag_value}` — filter with: chump gap list --skills-required {tag_value}"
        );
    }

    Ok(())
}

// ── Helpers ───────────────────────────────────────────────────────────────

/// Returns `~/.chump/external/<owner>/<repo>/`.
fn external_repo_dir(owner_repo: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".chump")
        .join("external")
        .join(owner_repo)
}

/// Extract `owner/repo` from a GitHub/GitLab HTTPS or SSH URL.
fn extract_owner_repo(url: &str) -> Result<String> {
    // Normalise: strip trailing `.git`
    let stripped = url.trim_end_matches('/').trim_end_matches(".git");

    // SSH: git@github.com:owner/repo
    if let Some(rest) = stripped.strip_prefix("git@") {
        let colon = rest
            .find(':')
            .ok_or_else(|| anyhow!("malformed SSH URL: {url}"))?;
        return Ok(rest[colon + 1..].to_string());
    }

    // HTTPS: https://github.com/owner/repo
    let without_scheme = stripped
        .trim_start_matches("https://")
        .trim_start_matches("http://");
    let slash = without_scheme
        .find('/')
        .ok_or_else(|| anyhow!("malformed URL: {url}"))?;
    let path = &without_scheme[slash + 1..];
    // path = "owner/repo" or "owner/repo/..."
    let parts: Vec<&str> = path.splitn(3, '/').collect();
    if parts.len() < 2 || parts[0].is_empty() || parts[1].is_empty() {
        bail!("could not extract owner/repo from URL: {url}");
    }
    Ok(format!("{}/{}", parts[0], parts[1]))
}

/// Resolve a GitHub authentication token from the environment or `gh auth token`.
///
/// Priority order:
///   1. `$GH_TOKEN` (explicit fleet token — preferred for autonomous workers)
///   2. `$GITHUB_TOKEN` (alternative explicit token)
///   3. `gh auth token` output (works for interactive dev sessions)
///
/// Returns `None` if no token can be obtained (e.g. unauthenticated CI).
/// Never logs the token value — only redacted presence confirmations.
fn resolve_github_token() -> Option<String> {
    // 1. Explicit env var (preferred for autonomous fleet workers)
    if let Ok(t) = std::env::var("GH_TOKEN") {
        if !t.trim().is_empty() {
            eprintln!("chump onboard: using GH_TOKEN for clone auth");
            return Some(t.trim().to_string());
        }
    }
    // 2. Alternative explicit env var
    if let Ok(t) = std::env::var("GITHUB_TOKEN") {
        if !t.trim().is_empty() {
            eprintln!("chump onboard: using GITHUB_TOKEN for clone auth");
            return Some(t.trim().to_string());
        }
    }
    // 3. Ask the gh CLI (interactive dev sessions, keyring-backed)
    match Command::new("gh").args(["auth", "token"]).output() {
        Ok(o) if o.status.success() => {
            let t = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if !t.is_empty() {
                eprintln!("chump onboard: using gh auth token for clone auth");
                return Some(t);
            }
        }
        _ => {}
    }
    None
}

/// Inject a GitHub token into an HTTPS URL so private repos can be cloned.
///
/// Transforms `https://github.com/owner/repo` into
/// `https://x-access-token:TOKEN@github.com/owner/repo`.
/// Non-github.com URLs, SSH URLs, and local paths are returned unchanged.
///
/// The returned string MUST NOT be logged — it contains the live token.
fn inject_token_into_url(url: &str, token: &str) -> String {
    if !url.starts_with("https://github.com/") {
        return url.to_string();
    }
    let rest = &url["https://".len()..]; // "github.com/..."
    format!("https://x-access-token:{token}@{rest}")
}

/// Shallow-clone the repo to `dest` (depth 1).
///
/// For HTTPS GitHub URLs, automatically injects a token from
/// `$GH_TOKEN` / `$GITHUB_TOKEN` / `gh auth token` so private repos work.
/// Falls back to unauthenticated clone when no token is available (public repos).
fn shallow_clone(url: &str, dest: &Path) -> Result<()> {
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent).context("creating clone parent directory")?;
    }
    eprintln!("chump onboard: cloning {} ...", url);

    // Build the effective clone URL — inject auth token for GitHub HTTPS.
    let clone_url: String;
    let clone_url_ref: &str;
    if url.starts_with("https://github.com/") {
        match resolve_github_token() {
            Some(token) => {
                clone_url = inject_token_into_url(url, &token);
                clone_url_ref = &clone_url;
                eprintln!("chump onboard: authenticated clone (token injected, not logged)");
            }
            None => {
                eprintln!(
                    "chump onboard: WARN — no GitHub token found (GH_TOKEN, GITHUB_TOKEN, \
                     gh auth token all empty); falling back to unauthenticated clone. \
                     Private repos will fail."
                );
                clone_url_ref = url;
            }
        }
    } else {
        clone_url_ref = url;
    }

    let status = Command::new("git")
        .args([
            "clone",
            "--depth=1",
            "--quiet",
            clone_url_ref,
            &dest.to_string_lossy(),
        ])
        .status()
        .context("git clone failed — is git installed?")?;

    if !status.success() {
        // Exit non-zero on clone failure (AC-2: must not swallow clone errors).
        bail!(
            "git clone exited {} — check that the repo URL is correct and that \
             a GitHub token (GH_TOKEN / GITHUB_TOKEN / gh auth token) is available \
             for private repos",
            status
        );
    }
    Ok(())
}

/// Read a file relative to `root`, returning `(content, sha256_hex)` or `None`.
fn read_file_with_sha(root: &Path, rel: &str) -> Option<(String, String)> {
    let content = fs::read_to_string(root.join(rel)).ok()?;
    let sha = hex_sha256(content.as_bytes());
    Some((content, sha))
}

fn hex_sha256(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    hex::encode(h.finalize())
}

/// Truncate to at most `max_chars` characters (by char boundary).
fn truncate_chars(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let end = s
        .char_indices()
        .nth(max_chars)
        .map(|(i, _)| i)
        .unwrap_or(s.len());
    format!("{}… [truncated]", &s[..end])
}

fn first_line(s: &str) -> String {
    s.lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("(empty)")
        .trim()
        .to_string()
}

/// Run `git log --oneline -N` and return the output.
fn git_log(root: &Path, n: usize) -> String {
    let out = Command::new("git")
        .args([
            "-C",
            &root.to_string_lossy(),
            "log",
            "--oneline",
            &format!("-{n}"),
        ])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::new(),
    }
}

/// Attempt to fetch open issues + PRs from GitHub via `gh` CLI.
/// Returns empty string on any failure (gh unavailable, private repo, etc.).
fn fetch_gh_context(owner_repo: &str) -> String {
    // Only works for github.com slugs (not local paths or GitLab).
    if owner_repo.starts_with("local/") || owner_repo.contains("gitlab.com") {
        return String::new();
    }

    let mut parts: Vec<String> = Vec::new();

    // Issues
    let issues = Command::new("gh")
        .args([
            "issue",
            "list",
            "--repo",
            owner_repo,
            "--limit",
            "20",
            "--state",
            "open",
            "--json",
            "number,title,labels",
        ])
        .output();
    if let Ok(o) = issues {
        if o.status.success() {
            let s = String::from_utf8_lossy(&o.stdout);
            parts.push(format!("Open issues:\n{s}"));
        }
    }

    // PRs
    let prs = Command::new("gh")
        .args([
            "pr",
            "list",
            "--repo",
            owner_repo,
            "--limit",
            "10",
            "--state",
            "open",
            "--json",
            "number,title,headRefName",
        ])
        .output();
    if let Ok(o) = prs {
        if o.status.success() {
            let s = String::from_utf8_lossy(&o.stdout);
            parts.push(format!("Open PRs:\n{s}"));
        }
    }

    parts.join("\n")
}

fn extract_source_path(source: &str) -> String {
    // Heuristic: pick the first token that looks like a file path.
    for word in source.split_whitespace() {
        let w = word.trim_matches(|c: char| {
            !c.is_alphanumeric() && c != '/' && c != '.' && c != '_' && c != '-'
        });
        if w.contains('.') || w.contains('/') {
            return w.to_string();
        }
    }
    "unknown".to_string()
}

// ── Priority / Effort / Confidence parsing (case-insensitive, fallback) ──

fn parse_priority(s: &str) -> Priority {
    match s.trim().to_uppercase().as_str() {
        "P0" => Priority::P0,
        "P1" => Priority::P1,
        "P3" => Priority::P3,
        _ => Priority::P2,
    }
}

fn parse_effort(s: &str) -> Effort {
    match s.trim().to_lowercase().as_str() {
        "xs" => Effort::Xs,
        "s" => Effort::S,
        "l" => Effort::L,
        _ => Effort::M,
    }
}

fn parse_confidence(s: &str) -> Confidence {
    match s.trim().to_lowercase().as_str() {
        "high" => Confidence::High,
        "low" => Confidence::Low,
        _ => Confidence::Med,
    }
}

// ── Unit tests ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_owner_repo_https() {
        assert_eq!(
            extract_owner_repo("https://github.com/ehippy/derelict").unwrap(),
            "ehippy/derelict"
        );
        assert_eq!(
            extract_owner_repo("https://github.com/ehippy/derelict.git").unwrap(),
            "ehippy/derelict"
        );
        assert_eq!(
            extract_owner_repo("https://github.com/anthropics/anthropic-sdk-rust").unwrap(),
            "anthropics/anthropic-sdk-rust"
        );
    }

    #[test]
    fn test_extract_owner_repo_ssh() {
        assert_eq!(
            extract_owner_repo("git@github.com:ehippy/derelict.git").unwrap(),
            "ehippy/derelict"
        );
    }

    #[test]
    fn test_extract_owner_repo_bad_url() {
        assert!(extract_owner_repo("https://github.com/ehippy").is_err());
    }

    #[test]
    fn test_parse_args_basic() {
        let args: Vec<String> = vec!["https://github.com/ehippy/derelict".into()];
        let opts = parse_args(&args).unwrap();
        assert_eq!(opts.repo_url_or_path, "https://github.com/ehippy/derelict");
        assert_eq!(opts.max_gaps, 10);
        assert!(!opts.apply);
    }

    #[test]
    fn test_parse_args_apply_and_max_gaps() {
        let args: Vec<String> = vec![
            "https://github.com/foo/bar".into(),
            "--apply".into(),
            "--max-gaps".into(),
            "5".into(),
        ];
        let opts = parse_args(&args).unwrap();
        assert!(opts.apply);
        assert_eq!(opts.max_gaps, 5);
    }

    #[test]
    fn test_parse_args_missing_positional() {
        assert!(parse_args(&[]).is_err());
    }

    #[test]
    fn test_external_repo_dir() {
        let dir = external_repo_dir("ehippy/derelict");
        assert!(dir
            .to_string_lossy()
            .contains(".chump/external/ehippy/derelict"));
    }

    #[test]
    fn test_truncate_chars() {
        let s = "hello world";
        assert_eq!(truncate_chars(s, 100), "hello world");
        let truncated = truncate_chars(s, 5);
        assert!(truncated.starts_with("hello"));
        assert!(truncated.contains("truncated"));
    }

    #[test]
    fn test_parse_priority_fallback() {
        assert_eq!(parse_priority("P1"), Priority::P1);
        assert_eq!(parse_priority("junk"), Priority::P2);
    }

    #[test]
    fn test_parse_effort_fallback() {
        assert_eq!(parse_effort("xs"), Effort::Xs);
        assert_eq!(parse_effort("junk"), Effort::M);
    }

    #[test]
    fn test_parse_confidence_fallback() {
        assert_eq!(parse_confidence("high"), Confidence::High);
        assert_eq!(parse_confidence("junk"), Confidence::Med);
    }

    // ── Token injection tests (EFFECTIVE-112) ─────────────────────────────

    #[test]
    fn test_inject_token_github_https() {
        let url = "https://github.com/repairman29/BEAST-MODE";
        let result = inject_token_into_url(url, "ghp_TESTTOKEN123");
        assert_eq!(
            result,
            "https://x-access-token:ghp_TESTTOKEN123@github.com/repairman29/BEAST-MODE"
        );
    }

    #[test]
    fn test_inject_token_github_https_with_git_suffix() {
        let url = "https://github.com/owner/repo.git";
        let result = inject_token_into_url(url, "ghp_XYZ");
        assert_eq!(
            result,
            "https://x-access-token:ghp_XYZ@github.com/owner/repo.git"
        );
    }

    #[test]
    fn test_inject_token_non_github_unchanged() {
        // Non-github.com HTTPS — returned as-is (don't mangle GitLab etc.)
        let url = "https://gitlab.com/owner/repo";
        let result = inject_token_into_url(url, "sometoken");
        assert_eq!(result, url);
    }

    #[test]
    fn test_inject_token_ssh_url_unchanged() {
        // SSH URLs don't go through HTTPS auth
        let url = "git@github.com:owner/repo.git";
        let result = inject_token_into_url(url, "sometoken");
        assert_eq!(result, url);
    }

    #[test]
    fn test_inject_token_local_path_unchanged() {
        let url = "/Users/dev/myrepo";
        let result = inject_token_into_url(url, "sometoken");
        assert_eq!(result, url);
    }
}
