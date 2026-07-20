//! `chump onboard <repo-url-or-path>` — first-touch external-repo scanner.
//!
//! Flow:
//! 1. Clone (shallow, depth 1) to `~/.chump/external/<owner>/<repo>/clone/`
//!    if a URL is given; otherwise use the path as-is.
//! 2. Spawn an AGENTIC scout (EFFECTIVE-166): `claude -p --dangerously-skip-permissions
//!    --model <capable-model>` in the repo directory.  The scout explores the
//!    repo itself — reads README, manifest, test files, recent commits, open
//!    issues, failing CI, documented bugs (TODO/DIAGNOSIS/FIX.md) — then emits
//!    a JSON array of proposals, each citing a CONCRETE signal.
//!    Falls back to the `provider_cascade.complete()` path when the `claude`
//!    CLI is unavailable (offline / no OAUTH or API key) or when
//!    `CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED=1`.
//! 3. Surface as a markdown table to stdout; `--apply` runs `chump gap
//!    reserve` for each proposed gap, tagging `skills_required:
//!    external_repo:<owner>/<repo>`.
//! 4. Persist the scan result to
//!    `~/.chump/external/<owner>/<repo>/scans/onboard-scan-<ts>.json`
//!    per the INFRA-2116 schema.
//!
//! INFRA-2108 (META-123 Wave 2)
//!
//! INFRA-2275: adds `--schedule`, `--unschedule`, `--list-scheduled` for
//! per-repo launchd plist management (BEAST-MODE overnight loop slice 1/3).

use anyhow::{anyhow, bail, Context, Result};
use chrono::Utc;
use chump_handoff::external_repo_schema::{
    read_latest_scan, save_scan, validate_external_repo_tag, Confidence, Effort, InputRead,
    OnboardScan, Priority, ProposedGap, SourceOfEvidence,
};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::standard_missions::{check_l1_missions, l1_missions, MissionCheckResult};

// ── Constants ─────────────────────────────────────────────────────────────

const TOOL_VERSION: &str = env!("CARGO_PKG_VERSION");

// ── Public entry point ────────────────────────────────────────────────────

/// `chump onboard` subcommand. `args` is everything *after* `onboard`.
pub fn run(args: &[String]) -> i32 {
    // INFRA-2275: route --schedule / --unschedule / --list-scheduled before
    // the original scan parser so the scan positional-arg requirement doesn't
    // swallow them.
    if args.iter().any(|a| a == "--schedule") {
        return match run_schedule(args) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("chump onboard --schedule: {e:#}");
                1
            }
        };
    }
    if args.iter().any(|a| a == "--unschedule") {
        return match run_unschedule(args) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("chump onboard --unschedule: {e:#}");
                1
            }
        };
    }
    if args.iter().any(|a| a == "--list-scheduled") {
        return match run_list_scheduled(args) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("chump onboard --list-scheduled: {e:#}");
                1
            }
        };
    }
    // INFRA-2276: per-iter worker loop body, invoked by the launchd plist
    // installed by --schedule (INFRA-2275). Routed before run_inner for the
    // same reason as --schedule/--unschedule/--list-scheduled above.
    if args.iter().any(|a| a == "--iter-once") {
        return match run_iter_once(args) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("chump onboard --iter-once: {e:#}");
                1
            }
        };
    }
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
    println!();
    println!("Scheduling (INFRA-2275 — BEAST overnight loop slice 1/3):");
    println!("  --schedule <path>        Install a per-repo launchd plist and load it");
    println!("  --unschedule <path>      Unload the plist and remove from the schedule list");
    println!("  --list-scheduled [--json]  Show all scheduled repos");
    println!();
    println!();
    println!("Worker loop (INFRA-2276 — BEAST overnight loop slice 2/3):");
    println!("  --iter-once <path>       Run one worker iteration against a scheduled repo:");
    println!("                           pick the safest pickable proposed gap, ship it via");
    println!("                           `chump improve --apply`, and track consecutive");
    println!("                           failures for auto-pause. Invoked by the launchd plist.");
    println!();
    println!("Env overrides for --iter-once:");
    println!("  CHUMP_EXTERNAL_LOOP_PRIORITY_FLOOR  min priority to pick (default: P2)");
    println!("  CHUMP_EXTERNAL_LOOP_EFFORT_CEIL     max effort to pick (default: s)");
    println!(
        "  CHUMP_EXTERNAL_LOOP_MAX_FAILURES    consecutive failures before auto-pause (default: 3)"
    );
}

// ── Core logic ────────────────────────────────────────────────────────────

/// Drive an async future to completion from *within* chump's `#[tokio::main]`
/// runtime without nesting a new runtime (EFFECTIVE-133).
///
/// `onboard::run` is dispatched inside the multi-threaded Tokio runtime, so the
/// old `Runtime::new().block_on(...)` panicked with "Cannot start a runtime from
/// within a runtime". `block_in_place` parks the current worker thread as
/// blocking and the existing `Handle` drives the future on the live runtime.
/// Requires the multi-thread flavor (chump's `#[tokio::main]` default).
fn block_on_in_runtime<F: std::future::Future>(fut: F) -> F::Output {
    tokio::task::block_in_place(|| tokio::runtime::Handle::current().block_on(fut))
}

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

    // ── EFFECTIVE-166: Agentic scout — try capable model first ───────────
    //
    // Preferred path: spawn `claude -p --dangerously-skip-permissions
    // --model <capable-model>` in the repo directory so the agent can READ
    // files, run shell commands, and investigate the repo before proposing.
    // Each proposal must cite a CONCRETE signal (failing test, issue #N,
    // TODO in FILE:line, etc.) — generic proposals without evidence are
    // explicitly rejected in the prompt.
    //
    // Fallback (legacy): `provider_cascade.complete()` one-shot prompt.
    // Used when: `claude` CLI unavailable, OAUTH/API key absent, or
    // `CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED=1` kill-switch set.

    let agentic_disabled = std::env::var("CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);

    let raw_text: String = if !agentic_disabled {
        eprintln!("chump onboard: launching agentic scout (EFFECTIVE-166)...");
        match spawn_agentic_scout(&clone_dir, &owner_repo, max_g) {
            Ok(text) => {
                eprintln!(
                    "chump onboard: agentic scout complete ({} chars)",
                    text.len()
                );
                text
            }
            Err(e) => {
                eprintln!(
                    "chump onboard: agentic scout failed ({e:#}); falling back to provider cascade"
                );
                run_provider_cascade_scout(&context_body, &owner_repo, max_g)?
            }
        }
    } else {
        eprintln!("chump onboard: CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED=1, using provider cascade");
        run_provider_cascade_scout(&context_body, &owner_repo, max_g)?
    };

    // ── Parse LLM JSON response ───────────────────────────────────────────

    // EFFECTIVE-147: use truncation-tolerant parser — if the response was cut
    // off mid-object (max_tokens hit), salvage all complete objects rather than
    // returning an error with zero gaps.
    let llm_gaps: Vec<LlmGap> = parse_llm_gaps_tolerant(&raw_text).map_err(|e| {
        anyhow!(
            "failed to parse LLM response as JSON: {e}\nRaw (first 500): {}",
            &raw_text[..raw_text.len().min(500)]
        )
    })?;

    if llm_gaps.is_empty() {
        bail!("LLM returned no gap proposals");
    }

    // ── Convert to schema types ───────────────────────────────────────────

    let mut proposed_gaps: Vec<ProposedGap> = llm_gaps
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
            layer: g.layer.clone(),
            doctrine_justification: g.doctrine_justification.clone(),
        })
        .collect();

    // ── EFFECTIVE-201: Standard-mission injection (L1 FOUNDATION) ────────
    //
    // Check the five objective L1 foundation gates. For each gate that is
    // UNMET, prepend an L1-tagged ProposedGap before the LLM-proposed gaps.
    // Gates that are already satisfied are silently skipped.
    //
    // L1 gaps are prepended so the doctrine-order picker in `chump improve`
    // sees them first and selects them before L2/L3 work.
    let l1_gaps = inject_l1_gaps(&clone_dir, &owner_repo);
    if !l1_gaps.is_empty() {
        eprintln!(
            "chump onboard: injecting {} unmet L1 foundation gap(s)",
            l1_gaps.len()
        );
        let scout_gaps = proposed_gaps;
        proposed_gaps = l1_gaps;
        proposed_gaps.extend(scout_gaps);
    }

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

// ── INFRA-2275: Scheduling (launchd plist management) ────────────────────

/// Schedule state file: `~/.chump/external-repo-schedule.json`.
/// Maps `repo_path -> { label, scheduled_at, last_iter_at }`.
fn schedule_state_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".chump")
        .join("external-repo-schedule.json")
}

/// Sanitize a repo path into a launchd-safe label component.
///
/// Replaces `/` with `-` and any remaining non-alphanumeric-non-hyphen-non-dot
/// chars with `_`. Truncates to 200 chars to stay well under launchd's ~256
/// label limit (we need room for the `com.chump.external-repo.` prefix).
fn sanitize_label_component(path: &str) -> String {
    let replaced: String = path
        .chars()
        .map(|c| match c {
            '/' => '-',
            c if c.is_alphanumeric() || c == '-' || c == '.' => c,
            _ => '_',
        })
        .collect();
    // Trim leading/trailing hyphens that result from leading `/`
    let trimmed = replaced.trim_matches('-');
    let truncated = if trimmed.len() > 200 {
        &trimmed[..200]
    } else {
        trimmed
    };
    truncated.to_string()
}

/// Build the full launchd label for a repo path.
fn plist_label(repo_path: &str) -> String {
    format!(
        "com.chump.external-repo.{}",
        sanitize_label_component(repo_path)
    )
}

/// Plist installation directory for per-user launchd agents.
fn launchd_agents_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join("Library").join("LaunchAgents")
}

/// Path where we install the generated plist.
fn plist_install_path(label: &str) -> PathBuf {
    launchd_agents_dir().join(format!("{label}.plist"))
}

/// Load current schedule state from disk. Returns empty map on missing file.
fn load_schedule_state() -> Result<HashMap<String, serde_json::Value>> {
    let path = schedule_state_path();
    if !path.exists() {
        return Ok(HashMap::new());
    }
    let content = fs::read_to_string(&path)
        .with_context(|| format!("reading schedule state {}", path.display()))?;
    let map: HashMap<String, serde_json::Value> = serde_json::from_str(&content)
        .with_context(|| format!("parsing schedule state {}", path.display()))?;
    Ok(map)
}

/// Persist schedule state to disk (atomic write via temp file + rename).
fn save_schedule_state(state: &HashMap<String, serde_json::Value>) -> Result<()> {
    let path = schedule_state_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let tmp = path.with_extension("json.tmp");
    let content = serde_json::to_string_pretty(state).context("serializing schedule state")?;
    fs::write(&tmp, content).with_context(|| format!("writing {}", tmp.display()))?;
    fs::rename(&tmp, &path).with_context(|| format!("renaming to {}", path.display()))?;
    Ok(())
}

/// Render the plist template, substituting `{{LABEL}}`, `{{REPO_PATH}}`,
/// `{{CHUMP_BIN}}`, `{{LOG_OUT}}`, `{{LOG_ERR}}`.
fn render_plist_template(label: &str, repo_path: &str, sanitized: &str) -> Result<String> {
    let template_path = {
        // Locate the repo root relative to the running binary. Fall back to
        // the CHUMP_REPO_ROOT env var for testing.
        let repo_root = std::env::var("CHUMP_REPO_ROOT")
            .ok()
            .map(PathBuf::from)
            .or_else(|| {
                // Walk up from current binary dir looking for Cargo.toml
                std::env::current_exe().ok().and_then(|exe| {
                    let mut d = exe.parent()?.to_path_buf();
                    for _ in 0..6 {
                        if d.join("Cargo.toml").exists() {
                            return Some(d);
                        }
                        d = d.parent()?.to_path_buf();
                    }
                    None
                })
            })
            .or_else(|| {
                // Last resort: use current working directory
                std::env::current_dir().ok()
            });
        repo_root
            .ok_or_else(|| anyhow!("cannot locate repo root (try CHUMP_REPO_ROOT env var)"))?
            .join("scripts/plists/com.chump.external-repo-loop.plist.template")
    };

    let template = fs::read_to_string(&template_path)
        .with_context(|| format!("reading plist template {}", template_path.display()))?;

    let chump_bin = std::env::current_exe()
        .context("cannot determine chump binary path")?
        .to_string_lossy()
        .to_string();

    let log_out = format!("/tmp/chump-external-repo-{sanitized}.out.log");
    let log_err = format!("/tmp/chump-external-repo-{sanitized}.err.log");

    let rendered = template
        .replace("{{LABEL}}", label)
        .replace("{{REPO_PATH}}", repo_path)
        .replace("{{CHUMP_BIN}}", &chump_bin)
        .replace("{{LOG_OUT}}", &log_out)
        .replace("{{LOG_ERR}}", &log_err);

    Ok(rendered)
}

/// `chump onboard --schedule <repo-path>` handler.
fn run_schedule(args: &[String]) -> Result<()> {
    // Find the repo path argument (the positional arg after --schedule)
    let repo_path = {
        let mut found: Option<String> = None;
        let mut i = 0;
        while i < args.len() {
            if args[i] == "--schedule" {
                i += 1;
                let v = args
                    .get(i)
                    .ok_or_else(|| anyhow!("--schedule requires a repo path argument"))?;
                found = Some(v.clone());
                break;
            }
            i += 1;
        }
        found.ok_or_else(|| anyhow!("--schedule requires a repo path argument"))?
    };

    // Resolve to absolute path
    let abs_path = if repo_path.starts_with('/') {
        PathBuf::from(&repo_path)
    } else {
        std::env::current_dir()
            .context("getting cwd")?
            .join(&repo_path)
    };
    let abs_str = abs_path.to_string_lossy().to_string();

    let label = plist_label(&abs_str);
    let sanitized = sanitize_label_component(&abs_str);

    eprintln!("chump onboard: scheduling {} (label: {label})", abs_str);

    // Render and install the plist
    let plist_content = render_plist_template(&label, &abs_str, &sanitized)?;
    let agents_dir = launchd_agents_dir();
    fs::create_dir_all(&agents_dir)
        .with_context(|| format!("creating LaunchAgents dir {}", agents_dir.display()))?;

    let install_path = plist_install_path(&label);
    fs::write(&install_path, &plist_content)
        .with_context(|| format!("writing plist to {}", install_path.display()))?;

    // Load via launchctl
    let load_status = Command::new("launchctl")
        .args(["load", "-w", &install_path.to_string_lossy()])
        .status()
        .context("running launchctl load (is this macOS?)")?;

    if !load_status.success() {
        // Clean up the installed plist so we don't leave a half-loaded entry
        let _ = fs::remove_file(&install_path);
        bail!(
            "launchctl load exited {} — plist removed; check launchd logs",
            load_status
        );
    }

    // Persist to schedule state
    let mut state = load_schedule_state()?;
    let ts = Utc::now().to_rfc3339();
    state.insert(
        abs_str.clone(),
        serde_json::json!({
            "label": label,
            "scheduled_at": ts,
            "last_iter_at": null
        }),
    );
    save_schedule_state(&state)?;

    println!("scheduled: {abs_str}");
    println!("  label:   {label}");
    println!("  plist:   {}", install_path.display());
    println!();
    println!("NOTE: --iter-once (worker loop body) is not yet implemented;");
    println!("      the plist will run at 03:17 daily but the worker is a no-op");
    println!("      until INFRA-2276 ships.");

    // Emit ambient event
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "external_repo_scheduled".to_string(),
        source: Some("chump-onboard".to_string()),
        fields: vec![
            ("repo_path".to_string(), abs_str.clone()),
            ("plist_label".to_string(), label.clone()),
        ],
        ..Default::default()
    });

    Ok(())
}

/// `chump onboard --unschedule <repo-path>` handler.
fn run_unschedule(args: &[String]) -> Result<()> {
    let repo_path = {
        let mut found: Option<String> = None;
        let mut i = 0;
        while i < args.len() {
            if args[i] == "--unschedule" {
                i += 1;
                let v = args
                    .get(i)
                    .ok_or_else(|| anyhow!("--unschedule requires a repo path argument"))?;
                found = Some(v.clone());
                break;
            }
            i += 1;
        }
        found.ok_or_else(|| anyhow!("--unschedule requires a repo path argument"))?
    };

    let abs_path = if repo_path.starts_with('/') {
        PathBuf::from(&repo_path)
    } else {
        std::env::current_dir()
            .context("getting cwd")?
            .join(&repo_path)
    };
    let abs_str = abs_path.to_string_lossy().to_string();

    let label = plist_label(&abs_str);
    let install_path = plist_install_path(&label);

    eprintln!("chump onboard: unscheduling {} (label: {label})", abs_str);

    // Unload via launchctl (tolerant of already-unloaded)
    if install_path.exists() {
        let unload_status = Command::new("launchctl")
            .args(["unload", "-w", &install_path.to_string_lossy()])
            .status()
            .context("running launchctl unload")?;
        if !unload_status.success() {
            eprintln!(
                "chump onboard: WARN launchctl unload exited {} (may already be unloaded)",
                unload_status
            );
        }
        fs::remove_file(&install_path)
            .with_context(|| format!("removing plist {}", install_path.display()))?;
        println!("unloaded and removed: {}", install_path.display());
    } else {
        eprintln!(
            "chump onboard: plist not found at {} (may already be removed)",
            install_path.display()
        );
    }

    // Remove from schedule state
    let mut state = load_schedule_state()?;
    let was_present = state.remove(&abs_str).is_some();
    save_schedule_state(&state)?;

    if was_present {
        println!("removed from schedule list: {abs_str}");
    } else {
        println!("WARN: {abs_str} was not in schedule list (state cleaned)");
    }

    // Emit ambient event
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "external_repo_unscheduled".to_string(),
        source: Some("chump-onboard".to_string()),
        fields: vec![
            ("repo_path".to_string(), abs_str.clone()),
            ("reason".to_string(), "operator_requested".to_string()),
        ],
        ..Default::default()
    });

    Ok(())
}

/// `chump onboard --list-scheduled [--json]` handler.
fn run_list_scheduled(args: &[String]) -> Result<()> {
    let json_mode = args.iter().any(|a| a == "--json");
    let state = load_schedule_state()?;

    if json_mode {
        // Build a JSON array of entries
        let entries: Vec<serde_json::Value> = state
            .iter()
            .map(|(repo_path, meta)| {
                let label = meta
                    .get("label")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let scheduled_at = meta
                    .get("scheduled_at")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let last_iter_at = meta
                    .get("last_iter_at")
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);
                let plist_loaded = plist_install_path(&label).exists();
                serde_json::json!({
                    "repo_path": repo_path,
                    "label": label,
                    "scheduled_at": scheduled_at,
                    "last_iter_at": last_iter_at,
                    "plist_loaded": plist_loaded,
                })
            })
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&entries).context("serializing list")?
        );
    } else {
        if state.is_empty() {
            println!("(no scheduled repos)");
            return Ok(());
        }
        println!("{:<60} {:<10} LABEL", "REPO_PATH", "LOADED");
        println!("{}", "-".repeat(90));
        let mut sorted: Vec<_> = state.iter().collect();
        sorted.sort_by_key(|(k, _)| k.as_str());
        for (repo_path, meta) in sorted {
            let label = meta
                .get("label")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let plist_loaded = plist_install_path(&label).exists();
            let loaded_str = if plist_loaded { "yes" } else { "no" };
            // Truncate long paths for readability
            let display_path = if repo_path.len() > 58 {
                format!("…{}", &repo_path[repo_path.len() - 57..])
            } else {
                repo_path.clone()
            };
            println!("{:<60} {:<10} {}", display_path, loaded_str, label);
        }
    }

    Ok(())
}

// ── INFRA-2276: worker loop (--iter-once) ─────────────────────────────────

/// Per-repo worker-loop state file: `~/.chump/external-repos/<sanitized>/loop-state.json`.
/// Schema matches INFRA-2277's plan so slice 3/3 can extend it without a rewrite.
fn loop_state_path(repo_path: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".chump")
        .join("external-repos")
        .join(sanitize_label_component(repo_path))
        .join("loop-state.json")
}

/// Load the per-repo loop state. Returns defaults (zeroed counters) on missing file.
fn load_loop_state(repo_path: &str) -> Result<serde_json::Value> {
    let path = loop_state_path(repo_path);
    if !path.exists() {
        return Ok(serde_json::json!({
            "last_iter_ts": null,
            "consecutive_failures": 0,
            "iter_count_total": 0,
            "ship_count_total": 0
        }));
    }
    let content = fs::read_to_string(&path)
        .with_context(|| format!("reading loop state {}", path.display()))?;
    serde_json::from_str(&content).with_context(|| format!("parsing loop state {}", path.display()))
}

/// Persist the per-repo loop state (atomic write via temp file + rename).
fn save_loop_state(repo_path: &str, state: &serde_json::Value) -> Result<()> {
    let path = loop_state_path(repo_path);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let tmp = path.with_extension("json.tmp");
    let content = serde_json::to_string_pretty(state).context("serializing loop state")?;
    fs::write(&tmp, content).with_context(|| format!("writing {}", tmp.display()))?;
    fs::rename(&tmp, &path).with_context(|| format!("renaming to {}", path.display()))?;
    Ok(())
}

/// Rank a `Priority` so "safest" (lowest-stakes) gaps sort highest.
/// Declaration order is P0 (unblocking emergency) .. P3 (nice-to-have), so the
/// numeric rank matches the enum's own ordering.
fn priority_rank(p: Priority) -> u8 {
    match p {
        Priority::P0 => 0,
        Priority::P1 => 1,
        Priority::P2 => 2,
        Priority::P3 => 3,
    }
}

fn parse_priority_floor(s: &str) -> Priority {
    match s.trim().to_uppercase().as_str() {
        "P0" => Priority::P0,
        "P1" => Priority::P1,
        "P3" => Priority::P3,
        _ => Priority::P2,
    }
}

/// Rank an `Effort` so smaller efforts sort lower (Xs=0 .. L=3).
fn effort_rank(e: Effort) -> u8 {
    match e {
        Effort::Xs => 0,
        Effort::S => 1,
        Effort::M => 2,
        Effort::L => 3,
    }
}

fn parse_effort_ceil(s: &str) -> Effort {
    match s.trim().to_lowercase().as_str() {
        "xs" => Effort::Xs,
        "m" => Effort::M,
        "l" => Effort::L,
        _ => Effort::S,
    }
}

/// Determine `owner/repo` for a scheduled local repo path: prefer the git
/// remote (so the pick step reads the same onboard scan `chump onboard
/// <url>` produced), falling back to the `local/<basename>` slug used by
/// `run_inner` for path-only (no-remote) repos.
fn owner_repo_for_scheduled_path(repo_path: &Path) -> String {
    let remote_url = Command::new("git")
        .args([
            "-C",
            &repo_path.to_string_lossy(),
            "remote",
            "get-url",
            "origin",
        ])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    if let Some(url) = remote_url {
        if let Ok(slug) = extract_owner_repo(&url) {
            return slug;
        }
    }

    repo_path
        .file_name()
        .and_then(|n| n.to_str())
        .map(|n| format!("local/{n}"))
        .unwrap_or_else(|| "local/repo".to_string())
}

/// Pick the safest pickable proposed gap from the latest onboard scan:
/// `priority >= floor` (i.e. P2/P3 by default — the low-stakes tiers) AND
/// `effort <= ceil` (i.e. xs/s by default). Ties broken by highest confidence.
fn pick_safest_gap(owner_repo: &str, floor: Priority, ceil: Effort) -> Result<Option<ProposedGap>> {
    let repo_dir = external_repo_dir(owner_repo);
    let scan = match read_latest_scan(&repo_dir)? {
        Some(s) => s,
        None => return Ok(None),
    };

    let floor_rank = priority_rank(floor);
    let ceil_rank = effort_rank(ceil);

    let mut candidates: Vec<ProposedGap> = scan
        .proposed_gaps
        .into_iter()
        .filter(|g| priority_rank(g.priority) >= floor_rank && effort_rank(g.effort) <= ceil_rank)
        .collect();

    candidates.sort_by_key(|g| match g.confidence {
        Confidence::High => 0,
        Confidence::Med => 1,
        Confidence::Low => 2,
    });

    Ok(candidates.into_iter().next())
}

/// Best-effort extraction of `#<N>` from a `chump improve` PR-number line
/// (`"[improve] PR number: #123"`), for escalation event fields.
fn extract_pr_number_from_output(output: &str) -> Option<String> {
    output.lines().find_map(|line| {
        let idx = line.find("PR number: #")?;
        let rest = &line[idx + "PR number: #".len()..];
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() {
            None
        } else {
            Some(digits)
        }
    })
}

/// Page the operator via `scripts/dispatch/operator-recall.sh --condition
/// <condition> --reason <reason>`. Best-effort — a failure here must not
/// crash the worker loop (the recall script itself is cooldown-gated so
/// repeated calls per iteration are safe).
fn page_operator(condition: &str, reason: &str) {
    let repo_root = std::env::var("CHUMP_REPO_ROOT")
        .ok()
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok());
    let Some(repo_root) = repo_root else {
        eprintln!("[onboard --iter-once] cannot locate repo root to page operator ({condition})");
        return;
    };
    let script = repo_root.join("scripts/dispatch/operator-recall.sh");
    if !script.exists() {
        eprintln!(
            "[onboard --iter-once] operator-recall.sh not found at {}",
            script.display()
        );
        return;
    }
    let status = Command::new("bash")
        .arg(&script)
        .args(["--condition", condition, "--reason", reason])
        .status();
    if let Err(e) = status {
        eprintln!("[onboard --iter-once] failed to invoke operator-recall.sh: {e}");
    }
}

/// `chump onboard --iter-once <repo-path>` handler (INFRA-2276).
///
/// Per-iter worker loop body, invoked by the launchd plist installed by
/// `--schedule` (INFRA-2275): pick the safest pickable proposed gap from the
/// repo's latest onboard scan, ship it via `chump improve --apply` (which
/// already gates on CI-green + anti-cosmetic-test + no-regression before
/// merging — the "all-checks-green" conservative bar), and track consecutive
/// failures for auto-pause.
fn run_iter_once(args: &[String]) -> Result<()> {
    let repo_path = {
        let mut found: Option<String> = None;
        let mut i = 0;
        while i < args.len() {
            if args[i] == "--iter-once" {
                i += 1;
                let v = args
                    .get(i)
                    .ok_or_else(|| anyhow!("--iter-once requires a repo path argument"))?;
                found = Some(v.clone());
                break;
            }
            i += 1;
        }
        found.ok_or_else(|| anyhow!("--iter-once requires a repo path argument"))?
    };

    let abs_path = if repo_path.starts_with('/') {
        PathBuf::from(&repo_path)
    } else {
        std::env::current_dir()
            .context("getting cwd")?
            .join(&repo_path)
    };
    let abs_str = abs_path.to_string_lossy().to_string();

    let max_failures: u32 = std::env::var("CHUMP_EXTERNAL_LOOP_MAX_FAILURES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3);

    let mut state = load_loop_state(&abs_str)?;
    let consecutive_failures = state
        .get("consecutive_failures")
        .and_then(|v| v.as_u64())
        .unwrap_or(0) as u32;

    if consecutive_failures >= max_failures {
        let reason = format!(
            "{abs_str}: {consecutive_failures} consecutive ship failures (threshold {max_failures})"
        );
        eprintln!("[onboard --iter-once] PAUSED: {reason}");
        let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
            kind: "external_repo_paused".to_string(),
            source: Some("chump-onboard".to_string()),
            fields: vec![
                ("repo_path".to_string(), abs_str.clone()),
                ("reason".to_string(), reason.clone()),
            ],
            ..Default::default()
        });
        page_operator("EXTERNAL_REPO_PAUSED", &reason);
        return Ok(());
    }

    let owner_repo = owner_repo_for_scheduled_path(&abs_path);

    let floor = parse_priority_floor(
        &std::env::var("CHUMP_EXTERNAL_LOOP_PRIORITY_FLOOR").unwrap_or_else(|_| "P2".to_string()),
    );
    let ceil = parse_effort_ceil(
        &std::env::var("CHUMP_EXTERNAL_LOOP_EFFORT_CEIL").unwrap_or_else(|_| "s".to_string()),
    );

    let picked = pick_safest_gap(&owner_repo, floor, ceil)?;

    let now = Utc::now().to_rfc3339();
    let iter_count_total = state
        .get("iter_count_total")
        .and_then(|v| v.as_u64())
        .unwrap_or(0)
        + 1;

    let Some(gap) = picked else {
        eprintln!("[onboard --iter-once] no pickable gap for {owner_repo} (floor={floor:?} ceil={ceil:?}) — no-op iter");
        state["last_iter_ts"] = serde_json::Value::String(now);
        state["iter_count_total"] = serde_json::Value::from(iter_count_total);
        save_loop_state(&abs_str, &state)?;
        return Ok(());
    };

    eprintln!(
        "[onboard --iter-once] {owner_repo}: picked \"{}\"",
        gap.title
    );

    let chump_bin = std::env::current_exe().context("cannot determine chump binary path")?;
    let output = Command::new(&chump_bin)
        .args([
            "improve",
            &owner_repo,
            "--apply",
            "--gap",
            &gap.title,
            "--clone-dir",
            &abs_str,
        ])
        .output()
        .context("spawning chump improve")?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    print!("{stdout}");
    eprint!("{}", String::from_utf8_lossy(&output.stderr));

    let shipped = output.status.success() && stdout.contains("Verdict: MERGE");

    let ship_count_total = state
        .get("ship_count_total")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    state["last_iter_ts"] = serde_json::Value::String(Utc::now().to_rfc3339());
    state["iter_count_total"] = serde_json::Value::from(iter_count_total);

    if shipped {
        state["consecutive_failures"] = serde_json::Value::from(0u64);
        state["ship_count_total"] = serde_json::Value::from(ship_count_total + 1);
        save_loop_state(&abs_str, &state)?;
        println!("[onboard --iter-once] SHIPPED: {}", gap.title);
        return Ok(());
    }

    // Not shipped: HELD verdict or a hard error either way counts as a
    // failure for the auto-pause counter.
    let new_failures = consecutive_failures + 1;
    state["consecutive_failures"] = serde_json::Value::from(new_failures as u64);
    save_loop_state(&abs_str, &state)?;

    let pr_number = extract_pr_number_from_output(&stdout).unwrap_or_default();
    let escalate_reason = if stdout.contains("Verdict: HELD") {
        stdout
            .lines()
            .find(|l| l.contains("Verdict: HELD"))
            .unwrap_or("Verdict: HELD")
            .trim()
            .to_string()
    } else {
        format!("chump improve exited {}", output.status)
    };

    eprintln!("[onboard --iter-once] ESCALATE: {owner_repo}: {escalate_reason}");
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "external_repo_escalation".to_string(),
        source: Some("chump-onboard".to_string()),
        fields: vec![
            ("repo_path".to_string(), abs_str.clone()),
            ("pr_number".to_string(), pr_number),
            ("escalate_reason".to_string(), escalate_reason.clone()),
        ],
        ..Default::default()
    });
    page_operator(
        "EXTERNAL_REPO_ESCALATION",
        &format!("{abs_str}: {escalate_reason}"),
    );

    Ok(())
}

// ── EFFECTIVE-201: L1 standard-mission injection ────────────────────────

/// Run the five L1 foundation checks against `clone_dir` and convert each
/// UNMET result into a `ProposedGap` tagged `layer = "L1"`.
///
/// Met gates are silently skipped — we only emit gaps for work that actually
/// needs doing. The resulting gaps are prepended to the proposed-gap list in
/// `run_inner` so the doctrine-order picker in `chump improve` sees them first.
///
/// The domain is derived from the pillar prefix in the mission title
/// (e.g. "INFRA: …" → domain "INFRA").
fn inject_l1_gaps(clone_dir: &Path, _owner_repo: &str) -> Vec<ProposedGap> {
    let missions = l1_missions();
    let results = check_l1_missions(clone_dir, missions);

    missions
        .iter()
        .zip(results.iter())
        .filter_map(|(mission, result)| match result {
            MissionCheckResult::Met => None,
            MissionCheckResult::Unmet {
                why,
                evidence_path,
                excerpt,
            } => {
                // Derive domain from the pillar prefix in the mission title.
                // E.g. "INFRA: clean build …" → "INFRA", "CREDIBLE: …" → "CREDIBLE".
                let domain = mission
                    .title
                    .split(':')
                    .next()
                    .unwrap_or("INFRA")
                    .trim()
                    .to_string();

                Some(ProposedGap {
                    title: mission.title.to_string(),
                    domain,
                    priority: Priority::P1,
                    effort: Effort::S,
                    confidence: Confidence::High,
                    source_of_evidence: SourceOfEvidence {
                        input_path: evidence_path.clone(),
                        section: format!("L1 foundation check: {}", mission.id),
                        excerpt: excerpt.clone(),
                    },
                    acceptance_criteria_draft: vec![
                        mission.done_criterion.to_string(),
                        format!("CI remains green after fixing {}", mission.id),
                    ],
                    layer: Some("L1".to_string()),
                    doctrine_justification: Some(format!(
                        "L1 FOUNDATION gate '{}' is unmet: {}",
                        mission.id, why
                    )),
                })
            }
        })
        .collect()
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

/// Resolve a *valid* explicit GitHub token from the environment.
///
/// Priority: `$GH_TOKEN` then `$GITHUB_TOKEN`. Each candidate is validated
/// against the GitHub API and we fall through to the next when a token is set
/// but rejected (EFFECTIVE-123: a stale `$GITHUB_TOKEN` sourced from an env
/// file must NOT block onboarding — the clone falls back to the `gh` keyring).
///
/// The `gh` keyring is intentionally NOT consulted here: a keyring/OAuth token
/// does not reliably re-validate or re-inject as a bearer (`gh api user` with
/// it returns "Bad credentials"), so the keyring path uses `gh repo clone`
/// natively instead (see `shallow_clone`).
///
/// Returns `None` if no valid explicit env token exists.
/// Never logs the token value — only redacted source/validity confirmations.
fn resolve_valid_env_token() -> Option<String> {
    let candidates = collect_env_token_candidates();
    first_valid_token(&candidates, validate_github_token)
}

/// Gather `(source-label, token)` env candidates in priority order, skipping
/// empties. Split out so the priority/fall-through logic is unit-testable
/// without touching process-global env or the network.
fn collect_env_token_candidates() -> Vec<(&'static str, String)> {
    let mut candidates: Vec<(&'static str, String)> = Vec::new();
    for (label, var) in [("GH_TOKEN", "GH_TOKEN"), ("GITHUB_TOKEN", "GITHUB_TOKEN")] {
        if let Ok(t) = std::env::var(var) {
            let t = t.trim().to_string();
            if !t.is_empty() {
                candidates.push((label, t));
            }
        }
    }
    candidates
}

/// Pure selection core (EFFECTIVE-123): return the first candidate the
/// `validate` fn accepts, falling through tokens that are set-but-rejected.
///
/// `validate` is tri-state:
///   * `Some(true)`  — token authenticates → use it.
///   * `Some(false)` — checked and rejected (e.g. 401) → fall through.
///   * `None`        — could not check (gh missing / offline) → use it
///     best-effort rather than reject a possibly-valid token (preserves the
///     pre-validation behavior for autonomous workers without the gh CLI).
fn first_valid_token<F>(candidates: &[(&'static str, String)], validate: F) -> Option<String>
where
    F: Fn(&str) -> Option<bool>,
{
    for (source, token) in candidates {
        match validate(token) {
            Some(true) => {
                eprintln!("chump onboard: using {source} for clone auth (validated)");
                return Some(token.clone());
            }
            Some(false) => {
                eprintln!(
                    "chump onboard: WARN — {source} is set but GitHub rejected it; falling \
                     through to the next auth source. Consider refreshing/removing it."
                );
            }
            None => {
                eprintln!(
                    "chump onboard: using {source} for clone auth (unvalidated — gh CLI \
                     unavailable to check)"
                );
                return Some(token.clone());
            }
        }
    }
    None
}

/// Validate a token against the GitHub API via `gh api user`.
///
/// Tri-state: `Some(true)` authenticates, `Some(false)` gh ran but the token
/// was rejected, `None` gh could not execute (missing binary / offline) so
/// validity is unknown — the caller then uses the token best-effort rather
/// than reject a possibly-valid one. The token is passed through the child
/// env, never logged.
fn validate_github_token(token: &str) -> Option<bool> {
    match Command::new("gh")
        .args(["api", "user"])
        .env("GH_TOKEN", token)
        .env("GITHUB_TOKEN", token)
        .output()
    {
        Ok(o) if o.status.success() => Some(true),
        Ok(_) => Some(false),
        Err(_) => None,
    }
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
/// GitHub HTTPS auth strategy (EFFECTIVE-123):
///   1. A *validated* explicit env token (`$GH_TOKEN` / `$GITHUB_TOKEN`) →
///      token-injected `git clone`. A set-but-invalid env token falls through.
///   2. Otherwise `gh repo clone` using gh's own keyring auth (env tokens
///      stripped so a stale `$GITHUB_TOKEN` can't poison gh's credential pick).
///   3. Otherwise an unauthenticated clone (public repos only).
///
/// Non-GitHub URLs clone directly. Any clone failure returns a non-zero error
/// (AC-2: clone errors are never swallowed).
fn shallow_clone(url: &str, dest: &Path) -> Result<()> {
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent).context("creating clone parent directory")?;
    }
    eprintln!("chump onboard: cloning {} ...", url);

    if url.starts_with("https://github.com/") {
        // 1. Validated explicit env token → token-injected clone.
        if let Some(token) = resolve_valid_env_token() {
            let auth_url = inject_token_into_url(url, &token);
            eprintln!("chump onboard: authenticated clone via env token (injected, not logged)");
            match run_git_clone(&auth_url, dest) {
                Ok(()) => return Ok(()),
                Err(_) => {
                    eprintln!(
                        "chump onboard: env-token clone failed; falling back to gh keyring auth"
                    );
                    let _ = fs::remove_dir_all(dest); // clear any partial checkout
                }
            }
        }
        // 2. gh's own keyring auth via `gh repo clone` (env tokens stripped).
        if gh_is_authenticated() {
            eprintln!("chump onboard: authenticated clone via gh keyring (gh repo clone)");
            return gh_repo_clone(url, dest);
        }
        eprintln!(
            "chump onboard: WARN — no valid GitHub auth (env token rejected/absent and gh not \
             logged in); falling back to unauthenticated clone. Private repos will fail."
        );
    }

    // Non-GitHub URL, or GitHub with no usable auth → direct clone.
    run_git_clone(url, dest)
}

/// Run `git clone --depth=1 --quiet <url> <dest>`; non-zero exit → Err
/// (AC-2: clone failures must surface, never be swallowed).
fn run_git_clone(url: &str, dest: &Path) -> Result<()> {
    let status = Command::new("git")
        .args([
            "clone",
            "--depth=1",
            "--quiet",
            url,
            &dest.to_string_lossy(),
        ])
        .status()
        .context("git clone failed — is git installed?")?;
    if !status.success() {
        bail!(
            "git clone exited {status} — check that the repo URL is correct and that valid \
             GitHub auth (GH_TOKEN / GITHUB_TOKEN / `gh auth login`) is available for private repos"
        );
    }
    Ok(())
}

/// True if `gh` reports an authenticated github.com login. `$GH_TOKEN` /
/// `$GITHUB_TOKEN` are stripped so a stale env token can't mask the keyring
/// credential we actually intend to use for `gh repo clone`.
fn gh_is_authenticated() -> bool {
    Command::new("gh")
        .args(["auth", "status", "--hostname", "github.com"])
        .env_remove("GH_TOKEN")
        .env_remove("GITHUB_TOKEN")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Clone via `gh repo clone OWNER/REPO dest` using gh's keyring auth. Stale
/// `$GH_TOKEN` / `$GITHUB_TOKEN` are stripped so gh uses its stored credential
/// — a keyring/OAuth token works natively here but NOT when re-injected as a
/// bearer (the EFFECTIVE-123 trap). Non-zero exit → Err.
fn gh_repo_clone(url: &str, dest: &Path) -> Result<()> {
    let slug = extract_owner_repo(url).context("could not parse owner/repo for gh repo clone")?;
    let status = Command::new("gh")
        .args([
            "repo",
            "clone",
            &slug,
            &dest.to_string_lossy(),
            "--",
            "--depth=1",
            "--quiet",
        ])
        .env_remove("GH_TOKEN")
        .env_remove("GITHUB_TOKEN")
        .status()
        .context("gh repo clone failed — is gh installed?")?;
    if !status.success() {
        bail!(
            "gh repo clone {slug} exited {status} — check the repo exists and that `gh auth \
             status` shows an authenticated github.com login"
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

// ── LLM gap struct (module-level so parse_llm_gaps_tolerant can reference it) ──

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
    /// EFFECTIVE-201: doctrine layer tag ("L1"/"L2"/"L3"), optional for back-compat.
    #[serde(default)]
    layer: Option<String>,
    /// EFFECTIVE-201: why this gap belongs to its doctrine layer.
    #[serde(default)]
    doctrine_justification: Option<String>,
}

/// EFFECTIVE-166: Spawn an agentic scout — a capable `claude -p` sub-agent
/// that runs in the repo directory and can READ files, execute shell commands,
/// query GitHub issues, inspect failing CI, and scan for documented bugs
/// before proposing gaps.
///
/// The scout is instructed to cite a CONCRETE signal for every proposal:
/// "failing test X", "open issue #N", "documented bug in FILE", "TODO at
/// FILE:line".  Proposals without evidence are explicitly disallowed.
///
/// Model routing:
/// - Online path (ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN present):
///   `claude-sonnet-4-5` — capable enough for multi-step repo reasoning.
/// - Offline / no cloud key: caller should have already checked; this
///   function propagates the `claude` exit code as an error so the caller
///   can fall back to provider_cascade.
///
/// The agent is given `--output-format json` so its final reply is emitted
/// as a JSON array on stdout, which we parse with `parse_llm_gaps_tolerant`.
///
/// Kill-switch: `CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED=1` bypasses this
/// function entirely (handled by the caller).
fn spawn_agentic_scout(clone_dir: &Path, owner_repo: &str, max_gaps: usize) -> Result<String> {
    // Select model: env-override first, then default capable cloud model.
    // CHUMP_ONBOARD_SCOUT_MODEL lets operators specify a local capable model
    // for offline operation (e.g. "llama3.3:70b", "qwen2.5:72b").
    let model = std::env::var("CHUMP_ONBOARD_SCOUT_MODEL")
        .ok()
        .filter(|m| !m.trim().is_empty())
        .unwrap_or_else(|| "claude-sonnet-4-5".to_string());

    let prompt = build_scout_prompt(owner_repo, max_gaps, clone_dir);

    eprintln!(
        "chump onboard: spawning agentic scout (model={model}, cwd={})",
        clone_dir.display()
    );

    // Spawn `claude -p <prompt> --dangerously-skip-permissions --model <model>`.
    // Capture stdout (the JSON proposals) while allowing stderr to inherit so
    // the operator sees the agent's exploration progress inline.
    let output = Command::new("claude")
        .arg("-p")
        .arg(&prompt)
        .arg("--dangerously-skip-permissions")
        .args(["--model", &model])
        .current_dir(clone_dir)
        .output()
        .context("spawn `claude -p` — is the claude CLI on PATH and authenticated?")?;

    if !output.status.success() {
        let stderr_snippet = String::from_utf8_lossy(&output.stderr);
        let snippet = stderr_snippet.chars().take(400).collect::<String>();
        bail!(
            "claude -p exited {} during scout; stderr: {}",
            output.status.code().unwrap_or(-1),
            snippet
        );
    }

    let raw = String::from_utf8_lossy(&output.stdout).to_string();
    if raw.trim().is_empty() {
        bail!("agentic scout produced empty stdout — no proposals returned");
    }
    Ok(raw)
}

/// Build the scouting prompt given to the agentic sub-agent.
///
/// EFFECTIVE-201: Extended to request doctrine-layer tagging. The agent now
/// classifies each proposal as:
///   - L2 (FULFILLMENT): a feature the README CLAIMS is working but has no test.
///   - L3 (REALIZATION): a latent idea the repo's own identity suggests — novel
///     work grounded in what the repo already is.
///
/// L1 (FOUNDATION) gaps are injected separately by `inject_l1_gaps` — the
/// scout does NOT generate L1 proposals (they are objective checks).
///
/// The prompt instructs the agent to EXPLORE first (read files, run git log,
/// query gh issues, check failing CI, scan for TODO/DIAGNOSIS/FIX files),
/// then emit a JSON array of proposals, each with a concrete evidence signal.
fn build_scout_prompt(owner_repo: &str, max_gaps: usize, clone_dir: &Path) -> String {
    let clone_path = clone_dir.to_string_lossy();
    format!(
        r#"You are a senior software engineer performing an AGENTIC first-touch scan of a repo on behalf of the Chump agent system.

REPO: {owner_repo}
REPO PATH ON DISK: {clone_path}

YOUR TASK:
1. EXPLORE the repo. Use your tools to investigate — do NOT propose from memory or generic advice.
   Required investigations (do ALL of these):
   a) Read README.md (understand what the project is and what it claims to do)
   b) Read the package manifest: package.json OR Cargo.toml OR pyproject.toml OR go.mod
   c) List the test suite: look in tests/, test/, src/__tests__/, spec/, *.test.*, *_test.rs, etc.
      Read 2–3 test files to understand test quality and coverage gaps.
   d) Run: git -C "{clone_path}" log --oneline -20
      Note any in-flight or incomplete work ("WIP", "TODO", "fix:" commits that lack follow-ups).
   e) Run: gh issue list --repo {owner_repo} --limit 20 --state open --json number,title,labels
      If gh is unavailable or returns an error, note it and continue.
   f) Run: gh run list --repo {owner_repo} --limit 10 --json name,status,conclusion
      Identify failing CI workflows if any.
   g) Search for documented bugs / TODO files:
      Run: find "{clone_path}" -maxdepth 3 -name "TODO*" -o -name "DIAGNOSIS*.md" -o -name "FIX*.md" -o -name "BUGS*" -o -name "KNOWN_ISSUES*" 2>/dev/null | head -10
      Read any files found.
   h) Read CLAUDE.md, AGENTS.md, or any ROADMAP.md if present.

2. CLASSIFY each proposal into a DOCTRINE LAYER:
   - L2 (FULFILLMENT): The README or docs CLAIM a feature is working, but there is no test
     that would fail if that feature were removed. Evidence: "README §X claims Y but no
     test exercises Y". Legible value, verifiable.
   - L3 (REALIZATION): A latent idea that fits naturally within this repo's identity —
     novel work the repo's purpose implies but hasn't yet done. Evidence: the repo's domain,
     patterns, or existing code shape make this a natural next step. Must be REVERSIBLE
     (no lock-in, can be reverted), WITHIN IDENTITY (not a pivot), and have LEGIBLE VALUE
     (operator can verify it mattered). Do NOT propose L3 ideas that would change the
     fundamental nature of the repo.
   NOTE: L1 (foundation: CI, build, secrets) gaps are handled separately — do NOT emit L1.

3. PROPOSE exactly {max_gaps} next-step gaps grounded in what you found.
   Aim for a mix: ~40% L2 (claim-gaps), ~60% L3 (realization theses). Prefer L2 when
   there are clear README-claim gaps; prefer L3 when the codebase is already well-tested.
   RULES FOR PROPOSALS:
   - Every proposal MUST cite a CONCRETE signal from your investigation:
     * "failing test X in FILE"
     * "open issue #N: TITLE"
     * "TODO at FILE:LINE"
     * "documented bug in FILENAME"
     * "git log shows incomplete commit: SHA SUBJECT"
     * "failing CI workflow NAME"
     * "README states X but no implementation exists for X"
     * "repo pattern Y implies Z is the natural next step"
   - A proposal with NO concrete signal is NOT allowed.
   - Use Chump conventions:
     * domain: EFFECTIVE | INFRA | DOC | CREDIBLE | RESILIENT
     * title: pillar-prefix + short imperative (e.g. "EFFECTIVE: fix streaming timeout in api.ts")
     * priority: P0 / P1 / P2 / P3
     * effort: xs / s / m / l
     * confidence: high / med / low
     * source: one sentence citing the specific signal (file, line, issue #, commit SHA)
     * ac_draft: 2–3 testable acceptance criteria
     * layer: "L2" or "L3" (never "L1" — those are injected separately)
     * doctrine_justification: one sentence explaining why this is L2 or L3 per the doctrine

4. OUTPUT ONLY a JSON array — no prose before or after the array.
   Schema for each object:
   {{
     "title": "DOMAIN: short imperative",
     "domain": "EFFECTIVE|INFRA|DOC|CREDIBLE|RESILIENT",
     "priority": "P0|P1|P2|P3",
     "effort": "xs|s|m|l",
     "confidence": "high|med|low",
     "source": "concrete signal (file, issue #, commit SHA, TODO line)",
     "ac_draft": ["testable criterion 1", "testable criterion 2"],
     "layer": "L2|L3",
     "doctrine_justification": "one sentence: why L2 or L3 per the doctrine"
   }}

Begin your investigation now, then output the JSON array."#
    )
}

/// Legacy fallback: one-shot `provider_cascade.complete()` prompt.
///
/// Used when the `claude` CLI is unavailable or agentic mode is disabled.
/// This is the pre-EFFECTIVE-166 path — useful for fully offline environments
/// where no capable agentic model is reachable.
fn run_provider_cascade_scout(
    context_body: &str,
    owner_repo: &str,
    max_gaps: usize,
) -> Result<String> {
    let system_prompt = format!(
        "You are a senior software project manager. \
        Your job is to read an external repo's intent documents and propose {max_gaps} \
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
        Propose {max_gaps} next-step gaps for this repo."
    );

    eprintln!(
        "chump onboard: calling provider cascade ({max_gaps} gaps requested, legacy path)..."
    );

    block_on_in_runtime(async {
        let provider = crate::provider_cascade::build_provider();
        let messages = vec![axonerai::provider::Message {
            role: "user".into(),
            content: user_msg,
        }];
        // EFFECTIVE-147: bump max_tokens to 16384 so a full JSON array fits.
        let resp = provider
            .complete(messages, None, Some(16384), Some(system_prompt))
            .await?;
        Ok::<String, anyhow::Error>(resp.text.unwrap_or_default())
    })
}

/// Parse LLM JSON response into a list of gap proposals.
///
/// EFFECTIVE-147: tolerates a truncated response (LLM hit max_tokens mid-array).
/// Strategy:
///   1. Try full-array parse first — fast path for a well-formed response.
///   2. On failure, extract complete JSON objects from the raw text by tracking
///      brace depth; deserialize each complete `{...}` individually and collect
///      only the ones that succeed.  A trailing partial object (the truncated one)
///      is silently dropped, so a 10-gap array truncated after object 8 yields 8
///      gaps rather than an error.
///
/// Returns `Err` only when *no* objects can be salvaged at all.
fn parse_llm_gaps_tolerant(raw: &str) -> anyhow::Result<Vec<LlmGap>> {
    // Narrow to the JSON array region (between the outermost '[' and ']').
    let array_start = raw.find('[').unwrap_or(0);
    let array_end = raw.rfind(']').map(|i| i + 1).unwrap_or(raw.len());
    let slice = &raw[array_start..array_end];

    // ── Fast path: well-formed array ─────────────────────────────────────
    if let Ok(gaps) = serde_json::from_str::<Vec<LlmGap>>(slice) {
        return Ok(gaps);
    }

    // ── Salvage path: extract every complete {...} object ────────────────
    // Walk the raw text (not the slice) so we catch objects even when there
    // is no closing ']' (the truncation point may be before the bracket).
    let mut gaps: Vec<LlmGap> = Vec::new();
    let bytes = raw.as_bytes();
    let len = bytes.len();
    let mut i = 0;

    while i < len {
        if bytes[i] == b'{' {
            // Track nested braces to find the matching '}'.
            let obj_start = i;
            let mut depth: usize = 0;
            let mut in_string = false;
            let mut escape_next = false;

            while i < len {
                let b = bytes[i];
                if escape_next {
                    escape_next = false;
                    i += 1;
                    continue;
                }
                match b {
                    b'\\' if in_string => {
                        escape_next = true;
                    }
                    b'"' => {
                        in_string = !in_string;
                    }
                    b'{' if !in_string => {
                        depth += 1;
                    }
                    b'}' if !in_string => {
                        depth -= 1;
                        if depth == 0 {
                            // Found the matching close-brace — try to parse.
                            let obj_slice = &raw[obj_start..=i];
                            if let Ok(gap) = serde_json::from_str::<LlmGap>(obj_slice) {
                                gaps.push(gap);
                            }
                            i += 1;
                            break;
                        }
                    }
                    _ => {}
                }
                i += 1;
            }
        } else {
            i += 1;
        }
    }

    if gaps.is_empty() {
        anyhow::bail!("no complete JSON objects found in LLM response");
    }
    Ok(gaps)
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

    // --- EFFECTIVE-123: validate-and-fall-through token selection ---

    fn cands(pairs: &[(&'static str, &str)]) -> Vec<(&'static str, String)> {
        pairs.iter().map(|(s, t)| (*s, t.to_string())).collect()
    }

    #[test]
    fn test_first_valid_token_falls_through_invalid_to_valid() {
        // The EFFECTIVE-123 bug: a set-but-invalid GITHUB_TOKEN precedes the
        // valid gh-auth token. The resolver MUST skip the rejected ones and
        // land on the valid token instead of failing on the first.
        let candidates = cands(&[
            ("GH_TOKEN", "stale-1"),
            ("GITHUB_TOKEN", "stale-2"),
            ("gh auth token", "good-token"),
        ]);
        let got = first_valid_token(&candidates, |t| Some(t == "good-token"));
        assert_eq!(got.as_deref(), Some("good-token"));
    }

    #[test]
    fn test_first_valid_token_prefers_earliest_valid() {
        // When several validate, priority order wins (GH_TOKEN before gh-auth).
        let candidates = cands(&[("GH_TOKEN", "a"), ("gh auth token", "b")]);
        let got = first_valid_token(&candidates, |_| Some(true));
        assert_eq!(got.as_deref(), Some("a"));
    }

    #[test]
    fn test_first_valid_token_none_when_all_rejected() {
        let candidates = cands(&[("GH_TOKEN", "x"), ("GITHUB_TOKEN", "y")]);
        let got = first_valid_token(&candidates, |_| Some(false));
        assert_eq!(got, None);
    }

    #[test]
    fn test_first_valid_token_uncheckable_used_best_effort() {
        // gh CLI missing/offline (None) → don't reject a possibly-valid token;
        // use the first candidate best-effort (no regression for workers
        // that have GH_TOKEN but no gh binary).
        let candidates = cands(&[("GH_TOKEN", "maybe"), ("gh auth token", "other")]);
        let got = first_valid_token(&candidates, |_| None);
        assert_eq!(got.as_deref(), Some("maybe"));
    }

    #[test]
    fn test_first_valid_token_rejected_then_uncheckable() {
        // First rejected, second uncheckable → fall through the reject, then
        // use the uncheckable one best-effort.
        let candidates = cands(&[("GITHUB_TOKEN", "bad"), ("gh auth token", "unknown")]);
        let got = first_valid_token(&candidates, |t| if t == "bad" { Some(false) } else { None });
        assert_eq!(got.as_deref(), Some("unknown"));
    }

    #[test]
    fn test_first_valid_token_empty_candidates_is_none() {
        let candidates: Vec<(&'static str, String)> = Vec::new();
        let got = first_valid_token(&candidates, |_| Some(true));
        assert_eq!(got, None);
    }

    // EFFECTIVE-133: the onboard provider-cascade must drive its async LLM call
    // on the EXISTING tokio runtime (block_on_in_runtime = block_in_place +
    // Handle::current), NEVER a nested Runtime::new — which panicked with
    // "Cannot start a runtime from within a runtime". Run the helper from inside
    // a multi-thread runtime (chump's #[tokio::main] flavor) and assert no panic
    // + correct value. No network: a trivial stand-in future exercises the same
    // scheduling path the real cascade uses.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn block_on_in_runtime_no_nested_panic() {
        let got = block_on_in_runtime(async { 40 + 2 });
        assert_eq!(got, 42);
    }

    // ── EFFECTIVE-147: truncation-tolerant JSON parser ────────────────────

    /// Helper: build a minimal well-formed JSON object string for a gap.
    fn make_gap_obj(title: &str) -> String {
        format!(
            r#"{{"title":"{title}","domain":"EFFECTIVE","priority":"P1","effort":"s","confidence":"high","source":"README.md","ac_draft":["test passes"]}}"#
        )
    }

    #[test]
    fn test_parse_llm_gaps_tolerant_well_formed() {
        // Fast path: a complete JSON array is parsed without salvage.
        let obj1 = make_gap_obj("gap one");
        let obj2 = make_gap_obj("gap two");
        let input = format!("[{obj1},{obj2}]");
        let gaps = parse_llm_gaps_tolerant(&input).unwrap();
        assert_eq!(gaps.len(), 2);
        assert_eq!(gaps[0].title, "gap one");
        assert_eq!(gaps[1].title, "gap two");
    }

    #[test]
    fn test_parse_llm_gaps_tolerant_truncated_array() {
        // Regression for EFFECTIVE-147: array truncated mid-object (EOF while
        // parsing the 3rd object) — must salvage the 2 completed objects.
        let obj1 = make_gap_obj("gap one");
        let obj2 = make_gap_obj("gap two");
        // Partial 3rd object — cut off in the middle of the title value.
        let partial = r#"{"title":"gap thr"#;
        let input = format!("[{obj1},{obj2},{partial}");
        let gaps = parse_llm_gaps_tolerant(&input).unwrap();
        assert_eq!(
            gaps.len(),
            2,
            "should salvage 2 complete objects, not error"
        );
        assert_eq!(gaps[0].title, "gap one");
        assert_eq!(gaps[1].title, "gap two");
    }

    #[test]
    fn test_parse_llm_gaps_tolerant_single_complete_then_truncated() {
        // Even one salvaged gap is success, not an error.
        let obj1 = make_gap_obj("only one");
        let partial = r#"{"title":"cut"#;
        let input = format!("[{obj1},{partial}");
        let gaps = parse_llm_gaps_tolerant(&input).unwrap();
        assert_eq!(gaps.len(), 1);
        assert_eq!(gaps[0].title, "only one");
    }

    #[test]
    fn test_parse_llm_gaps_tolerant_no_objects_is_err() {
        // Completely garbled input — should return Err, not panic.
        let result = parse_llm_gaps_tolerant("this is not json at all");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_llm_gaps_tolerant_prose_wrapping_array() {
        // LLM sometimes emits prose before/after the JSON array; must still parse.
        let obj = make_gap_obj("wrapped gap");
        let input = format!("Here are your gaps:\n[{obj}]\nDone.");
        let gaps = parse_llm_gaps_tolerant(&input).unwrap();
        assert_eq!(gaps.len(), 1);
        assert_eq!(gaps[0].title, "wrapped gap");
    }

    // ── EFFECTIVE-166: agentic scout tests ───────────────────────────────

    /// Verify `build_scout_prompt` includes the repo name, max_gaps count,
    /// and the clone path — so the spawned agent knows where to look.
    #[test]
    fn test_build_scout_prompt_contains_key_fields() {
        use std::path::Path;
        let prompt = build_scout_prompt("owner/myrepo", 7, Path::new("/tmp/clone/myrepo"));
        assert!(
            prompt.contains("owner/myrepo"),
            "prompt must contain owner/repo slug"
        );
        assert!(
            prompt.contains("/tmp/clone/myrepo"),
            "prompt must contain the clone path so the agent navigates there"
        );
        assert!(prompt.contains("7"), "prompt must embed the max_gaps count");
        // The prompt must explicitly require a concrete signal.
        assert!(
            prompt.contains("concrete signal") || prompt.contains("CONCRETE signal"),
            "prompt must demand a concrete evidence signal per proposal"
        );
        // The prompt must instruct the agent to check open issues.
        assert!(
            prompt.contains("gh issue list"),
            "prompt must ask the agent to query open GitHub issues"
        );
        // The prompt must instruct the agent to read tests.
        assert!(
            prompt.contains("test"),
            "prompt must ask the agent to investigate the test suite"
        );
        // JSON schema keys must be present.
        assert!(
            prompt.contains("ac_draft"),
            "prompt must define the ac_draft key in the JSON schema"
        );
    }

    /// Verify that `spawn_agentic_scout` passes the repo path as `--cwd` by
    /// running a mock `claude` shim that echoes the JSON proposals from env.
    ///
    /// Strategy: write a tiny shell script named `claude` to a temp dir, put
    /// that dir first on PATH, set CHUMP_ONBOARD_SCOUT_MODEL to a dummy value,
    /// and call `spawn_agentic_scout`.  The shim emits a pre-canned JSON array
    /// so we can assert:
    ///   1. `spawn_agentic_scout` invokes the subprocess (shim executes)
    ///   2. The returned text is the shim's JSON output
    ///   3. The output parses into `LlmGap` objects via `parse_llm_gaps_tolerant`
    #[test]
    fn test_spawn_agentic_scout_uses_mock_shim() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        // Build a tiny temp repo (needs to exist on disk).
        let repo_dir = std::env::temp_dir().join("chump-test-scout-repo");
        let _ = fs::create_dir_all(&repo_dir);

        // Shim dir — placed BEFORE real PATH so our fake `claude` wins.
        let shim_dir = std::env::temp_dir().join("chump-test-scout-shim");
        let _ = fs::create_dir_all(&shim_dir);
        let shim_path = shim_dir.join("claude");

        // The shim outputs a minimal valid JSON array to stdout and exits 0.
        let shim_json = r#"[{"title":"EFFECTIVE: fix failing login test in auth.test.ts","domain":"EFFECTIVE","priority":"P1","effort":"s","confidence":"high","source":"failing test auth.test.ts:42 — login_with_expired_token assertion fails","ac_draft":["auth.test.ts:42 passes","no regression in other auth tests"]}]"#;
        let shim_script = format!("#!/bin/sh\nprintf '%s\\n' '{}'\n", shim_json);
        fs::write(&shim_path, &shim_script).expect("write shim");
        fs::set_permissions(&shim_path, fs::Permissions::from_mode(0o755)).expect("chmod shim");

        // Prepend shim_dir to PATH.
        let old_path = std::env::var("PATH").unwrap_or_default();
        let new_path = format!("{}:{}", shim_dir.display(), old_path);
        // Use a test-local env override rather than mutating the process env.
        // We'll call spawn_agentic_scout with a patched PATH via std::env::set_var
        // (acceptable in single-threaded test context).
        // Safety: this test mutates PATH but restores it afterwards.
        unsafe {
            std::env::set_var("PATH", &new_path);
            // Use a dummy model name so shim doesn't need the real claude binary.
            std::env::set_var("CHUMP_ONBOARD_SCOUT_MODEL", "test-shim-model");
        }

        let result = spawn_agentic_scout(&repo_dir, "owner/test-repo", 1);

        // Restore env.
        unsafe {
            std::env::set_var("PATH", &old_path);
            std::env::remove_var("CHUMP_ONBOARD_SCOUT_MODEL");
        }

        let raw = result.expect("spawn_agentic_scout should succeed with shim on PATH");

        // The raw output must contain our shim's JSON.
        assert!(
            raw.contains("EFFECTIVE: fix failing login test"),
            "scout output must contain the shim's gap title; got: {raw}"
        );

        // The output must parse into LlmGap objects.
        let gaps =
            parse_llm_gaps_tolerant(&raw).expect("scout output must parse as valid LlmGap JSON");
        assert_eq!(gaps.len(), 1, "expected 1 proposal from shim");
        assert_eq!(
            gaps[0].domain, "EFFECTIVE",
            "proposal domain should be EFFECTIVE"
        );
        assert!(
            gaps[0].source.contains("auth.test.ts"),
            "source must cite a concrete file signal; got: {}",
            gaps[0].source
        );
    }

    /// Verify that `CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED=1` env var is respected
    /// by checking that the kill-switch env var name is referenced in onboard.rs.
    #[test]
    fn test_agentic_disabled_env_var_is_wired() {
        // Read the source of this very file to confirm the kill-switch var name
        // is present — guards against a future rename that forgets to update tests.
        let src = include_str!("onboard.rs");
        assert!(
            src.contains("CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED"),
            "kill-switch env var CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED must be referenced in onboard.rs"
        );
    }

    /// Verify the CHUMP_ONBOARD_SCOUT_MODEL env var is documented in env-vars-internal.txt.
    /// This is checked structurally — the test reads the file to confirm it.
    #[test]
    fn test_scout_model_env_var_registered() {
        // Locate env-vars-internal.txt relative to CARGO_MANIFEST_DIR.
        // CARGO_MANIFEST_DIR points to the crate root (src/../).
        // In a multi-crate workspace the binary crate is at the workspace root.
        let manifest_dir = env!("CARGO_MANIFEST_DIR");
        let env_file = std::path::Path::new(manifest_dir).join("scripts/ci/env-vars-internal.txt");
        if !env_file.exists() {
            // File doesn't exist at this path — try workspace root heuristic.
            // Skip rather than fail; the file check is advisory.
            return;
        }
        let content = std::fs::read_to_string(&env_file).unwrap_or_default();
        assert!(
            content.contains("CHUMP_ONBOARD_SCOUT_MODEL"),
            "CHUMP_ONBOARD_SCOUT_MODEL must be registered in scripts/ci/env-vars-internal.txt"
        );
        assert!(
            content.contains("CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED"),
            "CHUMP_ONBOARD_SCOUT_AGENTIC_DISABLED must be registered in scripts/ci/env-vars-internal.txt"
        );
    }

    // ── INFRA-2276: worker loop (--iter-once) ─────────────────────────────

    #[test]
    fn test_priority_rank_order() {
        assert!(priority_rank(Priority::P0) < priority_rank(Priority::P1));
        assert!(priority_rank(Priority::P1) < priority_rank(Priority::P2));
        assert!(priority_rank(Priority::P2) < priority_rank(Priority::P3));
    }

    #[test]
    fn test_effort_rank_order() {
        assert!(effort_rank(Effort::Xs) < effort_rank(Effort::S));
        assert!(effort_rank(Effort::S) < effort_rank(Effort::M));
        assert!(effort_rank(Effort::M) < effort_rank(Effort::L));
    }

    #[test]
    fn test_parse_priority_floor() {
        assert_eq!(
            priority_rank(parse_priority_floor("P0")),
            priority_rank(Priority::P0)
        );
        assert_eq!(
            priority_rank(parse_priority_floor("p3")),
            priority_rank(Priority::P3)
        );
        // Unrecognized / missing → default P2.
        assert_eq!(
            priority_rank(parse_priority_floor("bogus")),
            priority_rank(Priority::P2)
        );
    }

    #[test]
    fn test_parse_effort_ceil() {
        assert_eq!(
            effort_rank(parse_effort_ceil("xs")),
            effort_rank(Effort::Xs)
        );
        assert_eq!(effort_rank(parse_effort_ceil("L")), effort_rank(Effort::L));
        // Unrecognized / missing → default S.
        assert_eq!(
            effort_rank(parse_effort_ceil("bogus")),
            effort_rank(Effort::S)
        );
    }

    #[test]
    fn test_extract_pr_number_from_output() {
        let stdout =
            "[improve] PR opened: https://github.com/foo/bar/pull/42\n[improve] PR number: #42\n";
        assert_eq!(
            extract_pr_number_from_output(stdout),
            Some("42".to_string())
        );
        assert_eq!(extract_pr_number_from_output("no pr line here"), None);
    }

    #[test]
    fn test_owner_repo_for_scheduled_path_no_remote() {
        let tmp = std::env::temp_dir().join(format!(
            "chump-onboard-test-noremote-{}",
            std::process::id()
        ));
        let _ = fs::create_dir_all(&tmp);
        let status = Command::new("git")
            .args(["init", "-q"])
            .current_dir(&tmp)
            .status();
        if status.map(|s| s.success()).unwrap_or(false) {
            let slug = owner_repo_for_scheduled_path(&tmp);
            assert!(slug.starts_with("local/"), "got: {slug}");
        }
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_pick_safest_gap_filters_by_priority_and_effort() {
        use chump_handoff::external_repo_schema::SourceOfEvidence;

        let owner_repo = "test-owner/pick-safest-fixture";
        let repo_dir = external_repo_dir(owner_repo);
        let _ = fs::remove_dir_all(&repo_dir);

        let evidence = SourceOfEvidence {
            input_path: "README.md".to_string(),
            section: "test".to_string(),
            excerpt: "excerpt".to_string(),
        };
        let scan = OnboardScan {
            scan_timestamp: Utc::now(),
            external_repo: owner_repo.to_string(),
            tool_version: "test".to_string(),
            inputs_read: vec![],
            proposed_gaps: vec![
                ProposedGap {
                    title: "risky P0 gap".to_string(),
                    domain: "INFRA".to_string(),
                    priority: Priority::P0,
                    effort: Effort::Xs,
                    confidence: Confidence::High,
                    source_of_evidence: evidence.clone(),
                    acceptance_criteria_draft: vec![],
                    layer: None,
                    doctrine_justification: None,
                },
                ProposedGap {
                    title: "too-large P2 gap".to_string(),
                    domain: "INFRA".to_string(),
                    priority: Priority::P2,
                    effort: Effort::M,
                    confidence: Confidence::High,
                    source_of_evidence: evidence.clone(),
                    acceptance_criteria_draft: vec![],
                    layer: None,
                    doctrine_justification: None,
                },
                ProposedGap {
                    title: "safe P2/xs gap".to_string(),
                    domain: "INFRA".to_string(),
                    priority: Priority::P2,
                    effort: Effort::Xs,
                    confidence: Confidence::Med,
                    source_of_evidence: evidence.clone(),
                    acceptance_criteria_draft: vec![],
                    layer: None,
                    doctrine_justification: None,
                },
                ProposedGap {
                    title: "safe P3/s gap, higher confidence".to_string(),
                    domain: "INFRA".to_string(),
                    priority: Priority::P3,
                    effort: Effort::S,
                    confidence: Confidence::High,
                    source_of_evidence: evidence,
                    acceptance_criteria_draft: vec![],
                    layer: None,
                    doctrine_justification: None,
                },
            ],
        };
        save_scan(&repo_dir, &scan).expect("save fixture scan");

        let picked = pick_safest_gap(owner_repo, Priority::P2, Effort::S)
            .expect("pick should not error")
            .expect("expected a pickable gap");
        // Both "safe P2/xs gap" and "safe P3/s gap, higher confidence" pass the
        // filter; the higher-confidence one sorts first.
        assert_eq!(picked.title, "safe P3/s gap, higher confidence");

        let _ = fs::remove_dir_all(&repo_dir);
    }
}
