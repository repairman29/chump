//! INFRA-1691: `chump nugget` — CLI surface for Marcus M-D Phase 2 nuggets.
//!
//! Wraps the `chump_team::nuggets` Rust API (INFRA-1473, PR #2337) so operators
//! can add, list, search, keep, and soft-delete cross-agent context discoveries
//! from the command line.
//!
//! Subcommands:
//!
//!   chump nugget add    --gap <ID> --title 'X' --body '...'
//!                       [--kind gotcha|pattern|dead_end|failure_mode|convention|other]
//!                       [--repo URL] [--confidence low|medium|high]
//!   chump nugget list   [--repo URL] [--limit N]
//!   chump nugget search '<query>' [--repo URL] [--limit 5] [--min-sim 0.6]
//!   chump nugget keep   <UUID>            # promote keeper=true
//!   chump nugget delete <UUID>            # soft-delete
//!
//! Credentials are read from environment variables (`CHUMP_TEAM_URL`,
//! `CHUMP_TEAM_API_KEY`, optional `CHUMP_TEAM_JWT`, optional `OPENAI_API_KEY`).
//! `chump_team::ChumpTeamConfig::from_env` already falls back to defaults; this
//! CLI does not parse `~/.chump/team.toml` directly — that lives in the lib.
//!
//! Two extra env vars are required for `add`/`search` because the Rust API
//! needs UUIDs the env-config struct doesn't yet carry:
//!
//!   CHUMP_TEAM_ID   — UUID of the active team (RLS scope).
//!   CHUMP_USER_ID   — UUID of the author (audit trail).
//!
//! These will be wired into `ChumpTeamConfig` itself in a follow-up; for now
//! the CLI surfaces a clear error message when they're missing.

use chump_team::nuggets::{Confidence, EmbedMode, NuggetKind, NuggetQuery};
use chump_team::{ChumpTeam, ChumpTeamConfig};
use std::process::Command;
use uuid::Uuid;

/// Parsed subcommand surface.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Sub {
    Add,
    List,
    Search,
    Keep,
    Delete,
    Help,
    Unknown(String),
    /// No subcommand at all → help.
    None,
}

impl Sub {
    fn parse(s: Option<&str>) -> Sub {
        match s {
            None => Sub::None,
            Some("add") => Sub::Add,
            Some("list") | Some("ls") => Sub::List,
            Some("search") | Some("find") => Sub::Search,
            Some("keep") => Sub::Keep,
            Some("delete") | Some("rm") => Sub::Delete,
            Some("-h") | Some("--help") | Some("help") => Sub::Help,
            Some(other) => Sub::Unknown(other.to_string()),
        }
    }
}

/// Map a `--kind <s>` literal to the `NuggetKind` enum. Returns None on
/// unknown — caller surfaces a friendly error.
fn parse_kind(s: &str) -> Option<NuggetKind> {
    match s.to_ascii_lowercase().as_str() {
        "gotcha" => Some(NuggetKind::Gotcha),
        "pattern" => Some(NuggetKind::Pattern),
        "dead_end" | "dead-end" | "deadend" => Some(NuggetKind::DeadEnd),
        "failure_mode" | "failure-mode" | "failuremode" => Some(NuggetKind::FailureMode),
        "convention" => Some(NuggetKind::Convention),
        "other" => Some(NuggetKind::Other),
        _ => None,
    }
}

/// Map a `--confidence <s>` literal to the `Confidence` enum.
fn parse_confidence(s: &str) -> Option<Confidence> {
    match s.to_ascii_lowercase().as_str() {
        "low" => Some(Confidence::Low),
        "medium" | "med" => Some(Confidence::Medium),
        "high" => Some(Confidence::High),
        _ => None,
    }
}

/// Aggregated parsed args. Optional fields stay None when not provided so
/// downstream defaults can apply (e.g. `kind` defaults to `Other`).
#[derive(Debug, Default, Clone)]
struct Args {
    gap: Option<String>,
    title: Option<String>,
    body: Option<String>,
    kind: Option<NuggetKind>,
    confidence: Option<Confidence>,
    repo: Option<String>,
    limit: Option<usize>,
    min_sim: Option<f32>,
    /// Positional UUID for keep/delete.
    positional_uuid: Option<String>,
    /// Positional query string for search.
    positional_query: Option<String>,
    /// Set when --kind / --confidence was passed with a bad value. Surfaces
    /// a precise error from the dispatcher.
    bad_kind: Option<String>,
    bad_confidence: Option<String>,
    /// --help anywhere.
    help: bool,
}

/// Parse the remaining argv (after the subcommand token).
///
/// Recognizes the union of every flag any subcommand needs — keeping one
/// parser keeps the surface small and avoids per-subcommand duplication.
/// Unknown flags are ignored (forward-compat with future flags).
fn parse_args(argv: &[String]) -> Args {
    let mut a = Args::default();
    let mut i = 0;
    while i < argv.len() {
        let arg = &argv[i];
        let take_next = |i: usize| argv.get(i + 1).cloned();
        match arg.as_str() {
            "-h" | "--help" => a.help = true,
            "--gap" => {
                if let Some(v) = take_next(i) {
                    a.gap = Some(v);
                    i += 1;
                }
            }
            "--title" => {
                if let Some(v) = take_next(i) {
                    a.title = Some(v);
                    i += 1;
                }
            }
            "--body" => {
                if let Some(v) = take_next(i) {
                    a.body = Some(v);
                    i += 1;
                }
            }
            "--kind" => {
                if let Some(v) = take_next(i) {
                    match parse_kind(&v) {
                        Some(k) => a.kind = Some(k),
                        None => a.bad_kind = Some(v),
                    }
                    i += 1;
                }
            }
            "--confidence" => {
                if let Some(v) = take_next(i) {
                    match parse_confidence(&v) {
                        Some(c) => a.confidence = Some(c),
                        None => a.bad_confidence = Some(v),
                    }
                    i += 1;
                }
            }
            "--repo" => {
                if let Some(v) = take_next(i) {
                    a.repo = Some(v);
                    i += 1;
                }
            }
            "--limit" => {
                if let Some(v) = take_next(i) {
                    if let Ok(n) = v.parse::<usize>() {
                        a.limit = Some(n);
                    }
                    i += 1;
                }
            }
            "--min-sim" => {
                if let Some(v) = take_next(i) {
                    if let Ok(f) = v.parse::<f32>() {
                        a.min_sim = Some(f);
                    }
                    i += 1;
                }
            }
            // Positional (no leading dashes). First non-flag becomes the
            // query for search and the UUID for keep/delete; subsequent
            // positionals are ignored.
            s if !s.starts_with('-') => {
                if a.positional_query.is_none() {
                    a.positional_query = Some(s.to_string());
                }
                if a.positional_uuid.is_none() {
                    a.positional_uuid = Some(s.to_string());
                }
            }
            _ => {} // forward-compat: ignore unknown flags
        }
        i += 1;
    }
    a
}

/// Detect the current branch's gap id from `chump/<gap>-claim`, lowercased
/// to match `atomic_claim::run`. Returns None on any failure (not a git
/// repo, detached HEAD, branch doesn't match the pattern, etc.).
fn gap_from_current_branch() -> Option<String> {
    let out = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let branch = String::from_utf8_lossy(&out.stdout).trim().to_string();
    // pattern: chump/<gap-id-lower>-claim  e.g. chump/infra-1691-claim
    let rest = branch.strip_prefix("chump/")?;
    let stem = rest.strip_suffix("-claim")?;
    if stem.is_empty() {
        return None;
    }
    Some(stem.to_uppercase())
}

/// Resolve the repo URL via `git config --get remote.origin.url`. Returns
/// None when there's no origin or git is unavailable.
fn repo_url_from_git() -> Option<String> {
    let out = Command::new("git")
        .args(["config", "--get", "remote.origin.url"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// Load a UUID from an env var or surface a friendly error.
fn uuid_from_env(name: &str) -> std::result::Result<Uuid, String> {
    let raw = std::env::var(name).map_err(|_| {
        format!(
            "chump nugget: ${name} is required (UUID of the active team / user).\n\
             Set it in your shell or in ~/.chump/env.local. The Rust nugget API\n\
             requires it for RLS scoping and audit trails."
        )
    })?;
    Uuid::parse_str(raw.trim())
        .map_err(|e| format!("chump nugget: ${name}='{raw}' is not a valid UUID: {e}"))
}

fn print_help() {
    println!(
        "chump nugget — cross-agent context discoveries (INFRA-1691)

USAGE:
    chump nugget <SUBCOMMAND> [OPTIONS]

SUBCOMMANDS:
    add      Insert a new nugget (auto-embeds via OpenAI if OPENAI_API_KEY set)
    list     List nuggets (most recent first)
    search   Top-K cosine-similarity search; requires OPENAI_API_KEY
    keep     Promote a nugget to keeper=true (survives 30d expiry)
    delete   Soft-delete a nugget (RLS allows author + admin)

ADD:
    chump nugget add --gap <ID> --title 'X' --body '...'
                     [--kind gotcha|pattern|dead_end|failure_mode|convention|other]
                     [--repo URL] [--confidence low|medium|high]

LIST:
    chump nugget list [--repo URL] [--limit N]

SEARCH:
    chump nugget search '<query>' [--repo URL] [--limit 5] [--min-sim 0.6]

KEEP / DELETE:
    chump nugget keep   <UUID>
    chump nugget delete <UUID>

ENVIRONMENT:
    CHUMP_TEAM_URL      Supabase project URL (required for all subcommands)
    CHUMP_TEAM_API_KEY  Supabase API key (required)
    CHUMP_TEAM_JWT      User JWT — required for RLS to apply
    CHUMP_TEAM_ID       UUID of the active team (required for add)
    CHUMP_USER_ID       UUID of the author (required for add)
    OPENAI_API_KEY      OpenAI key for embeddings (optional; search no-ops without it)

DEFAULTS:
    --gap is inferred from the current branch (chump/<gap>-claim) when omitted
    --repo is inferred from `git config remote.origin.url` when omitted
    --kind defaults to 'other'
    --confidence defaults to 'medium'
    --limit defaults to 20 (list) or 5 (search)
    --min-sim defaults to 0.6 (matches NuggetQuery::default)

EXIT CODES:
    0   success
    1   API / network / RLS error
    2   bad usage (missing required arg, bad enum value)"
    );
}

/// Entry point — dispatched from `src/main.rs` like `preflight::run`.
pub fn run(argv: &[String]) -> i32 {
    // argv[0] is the subcommand token; argv[1..] are its flags/positionals.
    let sub = Sub::parse(argv.first().map(|s| s.as_str()));
    let rest: Vec<String> = argv.iter().skip(1).cloned().collect();
    let args = parse_args(&rest);

    if args.help || matches!(sub, Sub::Help | Sub::None) {
        print_help();
        return if matches!(sub, Sub::None) { 2 } else { 0 };
    }

    if let Sub::Unknown(u) = &sub {
        eprintln!("chump nugget: unknown subcommand '{u}' (want add|list|search|keep|delete)");
        return 2;
    }

    if let Some(bad) = &args.bad_kind {
        eprintln!(
            "chump nugget: bad --kind '{bad}' (want gotcha|pattern|dead_end|failure_mode|convention|other)"
        );
        return 2;
    }
    if let Some(bad) = &args.bad_confidence {
        eprintln!("chump nugget: bad --confidence '{bad}' (want low|medium|high)");
        return 2;
    }

    // Build a Tokio runtime up-front; every subcommand needs it.
    let rt = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("chump nugget: failed to start async runtime: {e}");
            return 1;
        }
    };

    // Config — read env vars; the lib surfaces clear errors if missing.
    let config = match ChumpTeamConfig::from_env() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("chump nugget: {e}\n\nSet CHUMP_TEAM_URL + CHUMP_TEAM_API_KEY (see `chump nugget --help`).");
            return 2;
        }
    };
    let team = ChumpTeam::new(config);

    match sub {
        Sub::Add => rt.block_on(do_add(&team, &args)),
        Sub::List => rt.block_on(do_list(&team, &args)),
        Sub::Search => rt.block_on(do_search(&team, &args)),
        Sub::Keep => rt.block_on(do_keep(&team, &args)),
        Sub::Delete => rt.block_on(do_delete(&team, &args)),
        // Already handled above; reach here only by mismatched enum.
        Sub::Help | Sub::None | Sub::Unknown(_) => 2,
    }
}

async fn do_add(team: &ChumpTeam, args: &Args) -> i32 {
    let title = match &args.title {
        Some(t) if !t.is_empty() => t.clone(),
        _ => {
            eprintln!("chump nugget add: --title is required");
            return 2;
        }
    };
    let body = match &args.body {
        Some(b) if !b.is_empty() => b.clone(),
        _ => {
            eprintln!("chump nugget add: --body is required");
            return 2;
        }
    };
    let gap_id = args.gap.clone().or_else(gap_from_current_branch);
    let repo_url = match args.repo.clone().or_else(repo_url_from_git) {
        Some(r) => r,
        None => {
            eprintln!(
                "chump nugget add: --repo is required (and no `remote.origin.url` was found)"
            );
            return 2;
        }
    };

    let team_id = match uuid_from_env("CHUMP_TEAM_ID") {
        Ok(u) => u,
        Err(e) => {
            eprintln!("{e}");
            return 2;
        }
    };
    let user_id = match uuid_from_env("CHUMP_USER_ID") {
        Ok(u) => u,
        Err(e) => {
            eprintln!("{e}");
            return 2;
        }
    };

    let kind = args.kind.unwrap_or(NuggetKind::Other);
    let confidence = args.confidence.unwrap_or(Confidence::Medium);

    match team
        .create_nugget(
            team_id,
            &repo_url,
            user_id,
            &title,
            &body,
            kind,
            confidence,
            EmbedMode::AutoEmbed,
            gap_id.as_deref(),
        )
        .await
    {
        Ok(n) => {
            println!(
                "ok: nugget {} created (gap={:?}, repo={})",
                n.id, gap_id, repo_url
            );
            0
        }
        Err(e) => {
            eprintln!("chump nugget add: {e}");
            1
        }
    }
}

async fn do_list(team: &ChumpTeam, args: &Args) -> i32 {
    let repo = args.repo.clone().or_else(repo_url_from_git);
    let limit = args.limit.unwrap_or(20);
    match team.list_nuggets(repo.as_deref(), limit).await {
        Ok(rows) => {
            if rows.is_empty() {
                eprintln!("(no nuggets found)");
                return 0;
            }
            for n in rows {
                println!(
                    "{}  {}  {}  keeper={}  gap={}\n    {}",
                    n.id,
                    n.created_at.format("%Y-%m-%d"),
                    format!("{:?}", n.kind).to_lowercase(),
                    n.keeper,
                    n.gap_id.unwrap_or_else(|| "-".to_string()),
                    n.title,
                );
            }
            0
        }
        Err(e) => {
            eprintln!("chump nugget list: {e}");
            1
        }
    }
}

async fn do_search(team: &ChumpTeam, args: &Args) -> i32 {
    let query_text = match &args.positional_query {
        Some(q) if !q.is_empty() => q.clone(),
        _ => {
            eprintln!("chump nugget search: positional query string is required");
            return 2;
        }
    };
    // Search requires OPENAI_API_KEY to embed the query. The lib returns an
    // empty Vec silently if the key is missing — surface that explicitly so
    // operators don't think their query just has no matches.
    if std::env::var("OPENAI_API_KEY")
        .map(|v| v.is_empty())
        .unwrap_or(true)
    {
        eprintln!(
            "chump nugget search: OPENAI_API_KEY is not set — semantic search is unavailable.\n\
             Use `chump nugget list` to browse without similarity ranking."
        );
        return 2;
    }
    let repo = args.repo.clone().or_else(repo_url_from_git);
    let limit = args.limit.unwrap_or(5);
    let min_sim = args.min_sim.unwrap_or(0.6);
    let q = NuggetQuery {
        query_text,
        repo_url: repo,
        kinds: vec![],
        limit,
        min_similarity: min_sim,
    };
    match team.search_nuggets(q).await {
        Ok(matches) => {
            if matches.is_empty() {
                eprintln!("(no matches above min-sim={min_sim})");
                return 0;
            }
            for m in matches {
                println!(
                    "{:.3}  {}  {}\n    {}",
                    m.similarity, m.nugget.id, m.nugget.title, m.nugget.body
                );
            }
            0
        }
        Err(e) => {
            eprintln!("chump nugget search: {e}");
            1
        }
    }
}

async fn do_keep(team: &ChumpTeam, args: &Args) -> i32 {
    let raw = match &args.positional_uuid {
        Some(u) => u.clone(),
        None => {
            eprintln!("chump nugget keep: positional <UUID> is required");
            return 2;
        }
    };
    let id = match Uuid::parse_str(&raw) {
        Ok(u) => u,
        Err(e) => {
            eprintln!("chump nugget keep: '{raw}' is not a valid UUID: {e}");
            return 2;
        }
    };
    match team.set_keeper(id, true).await {
        Ok(_) => {
            println!("ok: nugget {id} promoted to keeper");
            0
        }
        Err(e) => {
            eprintln!("chump nugget keep: {e}");
            1
        }
    }
}

async fn do_delete(team: &ChumpTeam, args: &Args) -> i32 {
    let raw = match &args.positional_uuid {
        Some(u) => u.clone(),
        None => {
            eprintln!("chump nugget delete: positional <UUID> is required");
            return 2;
        }
    };
    let id = match Uuid::parse_str(&raw) {
        Ok(u) => u,
        Err(e) => {
            eprintln!("chump nugget delete: '{raw}' is not a valid UUID: {e}");
            return 2;
        }
    };
    match team.delete_nugget(id).await {
        Ok(_) => {
            println!("ok: nugget {id} soft-deleted");
            0
        }
        Err(e) => {
            eprintln!("chump nugget delete: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sub_parse_canonical_and_aliases() {
        assert_eq!(Sub::parse(Some("add")), Sub::Add);
        assert_eq!(Sub::parse(Some("list")), Sub::List);
        assert_eq!(Sub::parse(Some("ls")), Sub::List);
        assert_eq!(Sub::parse(Some("search")), Sub::Search);
        assert_eq!(Sub::parse(Some("find")), Sub::Search);
        assert_eq!(Sub::parse(Some("keep")), Sub::Keep);
        assert_eq!(Sub::parse(Some("delete")), Sub::Delete);
        assert_eq!(Sub::parse(Some("rm")), Sub::Delete);
        assert_eq!(Sub::parse(Some("--help")), Sub::Help);
        assert_eq!(Sub::parse(Some("-h")), Sub::Help);
        assert_eq!(Sub::parse(None), Sub::None);
        match Sub::parse(Some("frobnicate")) {
            Sub::Unknown(s) => assert_eq!(s, "frobnicate"),
            _ => panic!("expected Unknown"),
        }
    }

    #[test]
    fn parse_kind_canonical_and_synonyms() {
        assert_eq!(parse_kind("gotcha"), Some(NuggetKind::Gotcha));
        assert_eq!(parse_kind("Pattern"), Some(NuggetKind::Pattern));
        assert_eq!(parse_kind("dead_end"), Some(NuggetKind::DeadEnd));
        assert_eq!(parse_kind("dead-end"), Some(NuggetKind::DeadEnd));
        assert_eq!(parse_kind("deadend"), Some(NuggetKind::DeadEnd));
        assert_eq!(parse_kind("failure_mode"), Some(NuggetKind::FailureMode));
        assert_eq!(parse_kind("failure-mode"), Some(NuggetKind::FailureMode));
        assert_eq!(parse_kind("convention"), Some(NuggetKind::Convention));
        assert_eq!(parse_kind("other"), Some(NuggetKind::Other));
        assert_eq!(parse_kind("nonsense"), None);
    }

    #[test]
    fn parse_confidence_canonical() {
        assert_eq!(parse_confidence("low"), Some(Confidence::Low));
        assert_eq!(parse_confidence("medium"), Some(Confidence::Medium));
        assert_eq!(parse_confidence("med"), Some(Confidence::Medium));
        assert_eq!(parse_confidence("high"), Some(Confidence::High));
        assert_eq!(parse_confidence("HIGH"), Some(Confidence::High));
        assert_eq!(parse_confidence("nope"), None);
    }

    #[test]
    fn parse_args_add_full_form() {
        let argv: Vec<String> = [
            "--gap",
            "INFRA-1691",
            "--title",
            "Branch hint",
            "--body",
            "chump/<gap>-claim is the convention",
            "--kind",
            "convention",
            "--confidence",
            "high",
            "--repo",
            "git@github.com:repairman29/chump.git",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let a = parse_args(&argv);
        assert_eq!(a.gap.as_deref(), Some("INFRA-1691"));
        assert_eq!(a.title.as_deref(), Some("Branch hint"));
        assert_eq!(
            a.body.as_deref(),
            Some("chump/<gap>-claim is the convention")
        );
        assert_eq!(a.kind, Some(NuggetKind::Convention));
        assert_eq!(a.confidence, Some(Confidence::High));
        assert_eq!(
            a.repo.as_deref(),
            Some("git@github.com:repairman29/chump.git")
        );
        assert!(a.bad_kind.is_none());
        assert!(a.bad_confidence.is_none());
    }

    #[test]
    fn parse_args_search_positional_query() {
        let argv: Vec<String> = ["how do I claim a gap", "--limit", "3", "--min-sim", "0.7"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let a = parse_args(&argv);
        assert_eq!(a.positional_query.as_deref(), Some("how do I claim a gap"));
        assert_eq!(a.limit, Some(3));
        assert_eq!(a.min_sim, Some(0.7));
    }

    #[test]
    fn parse_args_keep_positional_uuid() {
        let id = "11111111-2222-3333-4444-555555555555".to_string();
        let a = parse_args(std::slice::from_ref(&id));
        assert_eq!(a.positional_uuid.as_deref(), Some(id.as_str()));
    }

    #[test]
    fn parse_args_bad_kind_recorded() {
        let argv = vec!["--kind".to_string(), "frobnicate".to_string()];
        let a = parse_args(&argv);
        assert!(a.kind.is_none());
        assert_eq!(a.bad_kind.as_deref(), Some("frobnicate"));
    }

    #[test]
    fn parse_args_bad_confidence_recorded() {
        let argv = vec!["--confidence".to_string(), "very-high".to_string()];
        let a = parse_args(&argv);
        assert!(a.confidence.is_none());
        assert_eq!(a.bad_confidence.as_deref(), Some("very-high"));
    }

    #[test]
    fn parse_args_help_flag() {
        let a = parse_args(&["--help".to_string()]);
        assert!(a.help);
    }

    #[test]
    fn parse_args_ignores_unknown_flags() {
        let argv = vec![
            "--frobnicate".to_string(),
            "yes".to_string(),
            "--title".to_string(),
            "T".to_string(),
        ];
        let a = parse_args(&argv);
        // The positional "yes" after --frobnicate gets captured because the
        // parser doesn't know --frobnicate takes a value; this is acceptable
        // and matches the preflight forward-compat policy. The important
        // contract here is that --title still parses.
        assert_eq!(a.title.as_deref(), Some("T"));
    }

    #[test]
    fn parse_args_limit_invalid_is_ignored() {
        let a = parse_args(&["--limit".to_string(), "not-a-number".to_string()]);
        assert!(a.limit.is_none());
    }
}
