//! `chump-reviewer-routing` CLI — INFRA-1491.
//!
//! Subcommands:
//!   show   --pr <N>              — print suggested reviewers without requesting
//!   route  --pr <N> [--dry-run]  — compute + assign via `gh api` (default: actually assign)
//!   show   --files <p1,p2,...>   — preview against an ad-hoc file list (no PR query)
//!
//! Storage:
//!   <repo>/.chump/reviewers.toml — per-repo config (operator override, exclusion, mappings)
//!   <repo>/CODEOWNERS / .github/CODEOWNERS — standard GitHub CODEOWNERS
//!
//! Audit events (registered in EVENT_REGISTRY.yaml):
//!   kind=reviewer_routing_computed — emitted on every show / route invocation
//!   kind=reviewer_routing_requested — emitted on each successful gh-api reviewer add
//!
//! gh API integration:
//!   `gh pr view <N> --json files,author --jq` → touched files + author
//!   `gh pr edit <N> --add-reviewer <login>,...` → request reviewers
//!
//! Note: the bot-merge integration that calls this CLI on every PR open
//! is a follow-up gap to avoid colliding with active scripts/coord/bot-merge.sh
//! leases.

use chump_reviewer_routing::*;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    if argv.len() < 2 {
        print_usage();
        std::process::exit(2);
    }
    let cmd = argv[1].as_str();
    let rest: Vec<&str> = argv[2..].iter().map(|s| s.as_str()).collect();
    let result = match cmd {
        "show" => cmd_show(&rest),
        "route" => cmd_route(&rest),
        "-h" | "--help" | "help" => {
            print_usage();
            Ok(())
        }
        other => {
            eprintln!("chump-reviewer-routing: unknown subcommand: {other}");
            print_usage();
            std::process::exit(2);
        }
    };
    if let Err(e) = result {
        eprintln!("chump-reviewer-routing: {e:#}");
        std::process::exit(1);
    }
}

fn print_usage() {
    eprintln!(
        "Usage: chump-reviewer-routing <subcommand> [flags]\n\n\
         Subcommands:\n  \
           show --pr <N>              — print suggested reviewers for an open PR\n  \
           show --files <p1,p2,...>   — preview against an ad-hoc file list\n  \
           route --pr <N> [--dry-run] — compute + assign reviewers via gh api\n\n\
         Common flags:\n  \
           --json                     — machine-readable output\n  \
           --dry-run                  — show what WOULD be requested (route only)\n\n\
         Reads:\n  \
           <repo>/.chump/reviewers.toml (operator config)\n  \
           <repo>/CODEOWNERS or .github/CODEOWNERS"
    );
}

fn repo_root() -> PathBuf {
    std::env::var("CHUMP_REPO")
        .map(PathBuf::from)
        .ok()
        .filter(|p| p.is_dir())
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."))
}

fn parse_args(args: &[&str]) -> ParsedArgs {
    let mut pa = ParsedArgs::default();
    let mut i = 0;
    while i < args.len() {
        match args[i] {
            "--pr" => {
                if let Some(v) = args.get(i + 1) {
                    pa.pr_number = v.parse::<u64>().ok();
                }
                i += 2;
            }
            "--files" => {
                if let Some(v) = args.get(i + 1) {
                    pa.files = v.split(',').map(PathBuf::from).collect();
                }
                i += 2;
            }
            "--json" => {
                pa.json = true;
                i += 1;
            }
            "--dry-run" => {
                pa.dry_run = true;
                i += 1;
            }
            _ => {
                i += 1;
            }
        }
    }
    pa
}

#[derive(Default, Debug)]
struct ParsedArgs {
    pr_number: Option<u64>,
    files: Vec<PathBuf>,
    json: bool,
    dry_run: bool,
}

fn cmd_show(args: &[&str]) -> anyhow::Result<()> {
    let pa = parse_args(args);
    let repo = repo_root();
    let cfg = ReviewerConfig::from_repo_root(&repo)?;

    // Resolve touched files + author.
    let (files, author) = if !pa.files.is_empty() {
        (pa.files.clone(), None)
    } else if let Some(pr) = pa.pr_number {
        fetch_pr_files_and_author(pr)?
    } else {
        anyhow::bail!("show: pass either --pr <N> or --files <p1,p2,...>");
    };

    let set = compute_reviewer_set(&repo, &files, &cfg, author.as_deref())?;
    emit_computed_event(&pa, &set);
    print_reviewer_set(&set, pa.json);
    Ok(())
}

fn cmd_route(args: &[&str]) -> anyhow::Result<()> {
    let pa = parse_args(args);
    let pr = pa
        .pr_number
        .ok_or_else(|| anyhow::anyhow!("route: --pr <N> is required"))?;
    let repo = repo_root();
    let cfg = ReviewerConfig::from_repo_root(&repo)?;
    let (files, author) = fetch_pr_files_and_author(pr)?;
    let set = compute_reviewer_set(&repo, &files, &cfg, author.as_deref())?;
    emit_computed_event(&pa, &set);

    if set.reviewers.is_empty() {
        println!("[route] no reviewers suggested (empty set after dedupe/exclude)");
        return Ok(());
    }
    let logins: Vec<&str> = set.reviewers.iter().map(|r| r.login.as_str()).collect();
    let csv = logins.join(",");

    if pa.dry_run {
        println!("[route] --dry-run: would request reviewers: {}", csv);
        return Ok(());
    }

    // gh pr edit <N> --add-reviewer login1,login2,...
    let out = Command::new("gh")
        .arg("pr")
        .arg("edit")
        .arg(pr.to_string())
        .arg("--add-reviewer")
        .arg(&csv)
        .output()?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        anyhow::bail!("gh pr edit failed: {}", stderr.trim());
    }
    println!("[route] ✓ requested reviewers: {}", csv);
    emit_requested_event(pr, &set);
    Ok(())
}

/// Query GH for the PR's touched files and author login.
fn fetch_pr_files_and_author(pr: u64) -> anyhow::Result<(Vec<PathBuf>, Option<String>)> {
    let out = Command::new("gh")
        .arg("pr")
        .arg("view")
        .arg(pr.to_string())
        .arg("--json")
        .arg("files,author")
        .output()?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        anyhow::bail!("gh pr view failed: {}", stderr.trim());
    }
    let body = String::from_utf8_lossy(&out.stdout);
    // Hand-roll minimal JSON parse to avoid pulling serde_json: search for
    // the "path":"..." entries inside the "files" array, and "login":"..."
    // inside the "author" object. This is intentionally narrow; full JSON
    // parsing is overkill for two known shapes.
    let files = parse_files_paths(&body);
    let author = parse_author_login(&body);
    Ok((files, author))
}

fn parse_files_paths(body: &str) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let key = "\"path\":\"";
    let mut search = body;
    while let Some(idx) = search.find(key) {
        let after = &search[idx + key.len()..];
        if let Some(end) = after.find('"') {
            out.push(PathBuf::from(&after[..end]));
            search = &after[end + 1..];
        } else {
            break;
        }
    }
    out
}

fn parse_author_login(body: &str) -> Option<String> {
    // First "login":"<...>" appearing AFTER the "author": opener.
    let author_idx = body.find("\"author\":")?;
    let after_author = &body[author_idx..];
    let key = "\"login\":\"";
    let key_idx = after_author.find(key)?;
    let after = &after_author[key_idx + key.len()..];
    let end = after.find('"')?;
    Some(after[..end].to_string())
}

fn print_reviewer_set(set: &ReviewerSet, json: bool) {
    if json {
        let entries: Vec<String> = set
            .reviewers
            .iter()
            .map(|r| {
                let vias: Vec<String> =
                    r.via.iter().map(|v| format!("\"{}\"", v.as_str())).collect();
                format!(
                    "{{\"login\":\"{}\",\"via\":[{}]}}",
                    r.login,
                    vias.join(",")
                )
            })
            .collect();
        println!("{{\"reviewers\":[{}]}}", entries.join(","));
    } else if set.reviewers.is_empty() {
        println!("(no reviewers suggested)");
    } else {
        for r in &set.reviewers {
            let vias: Vec<&str> = r.via.iter().map(|v| v.as_str()).collect();
            println!("{:24}  via [{}]", r.login, vias.join(", "));
        }
    }
}

/// Audit events go to STDERR. Stdout stays clean for parseable JSON
/// output (`show --json` consumers must be able to read stdout as a
/// single JSON document). CI consumers tail the stderr stream into
/// ambient.jsonl via the per-call shell glue.
fn emit_computed_event(pa: &ParsedArgs, set: &ReviewerSet) {
    let ts = now_iso8601();
    let logins: Vec<String> = set
        .reviewers
        .iter()
        .map(|r| format!("\"{}\"", r.login))
        .collect();
    let pr_field = pa
        .pr_number
        .map(|n| format!(",\"pr\":{n}"))
        .unwrap_or_default();
    eprintln!(
        "{{\"ts\":\"{ts}\",\"kind\":\"reviewer_routing_computed\",\
\"reviewer_count\":{}{}}}",
        set.reviewers.len(),
        if logins.is_empty() {
            String::new()
        } else {
            format!(",\"reviewers\":[{}]", logins.join(","))
        } + &pr_field
    );
}

fn emit_requested_event(pr: u64, set: &ReviewerSet) {
    let ts = now_iso8601();
    let logins: Vec<String> = set
        .reviewers
        .iter()
        .map(|r| format!("\"{}\"", r.login))
        .collect();
    eprintln!(
        "{{\"ts\":\"{ts}\",\"kind\":\"reviewer_routing_requested\",\
\"pr\":{pr},\"reviewers\":[{}]}}",
        logins.join(",")
    );
}

/// Lightweight ISO-8601 now() without pulling chrono.
fn now_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = (secs / 86_400) as i64;
    let (y, m, d) = days_to_ymd(days);
    let rem = secs % 86_400;
    let h = (rem / 3600) as u32;
    let mi = ((rem % 3600) / 60) as u32;
    let s = (rem % 60) as u32;
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, h, mi, s)
}

fn days_to_ymd(mut days: i64) -> (i32, u32, u32) {
    days += 719_468;
    let era = if days >= 0 { days } else { days - 146_096 } / 146_097;
    let doe = (days - era * 146_097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i32 + (era * 400) as i32;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}
