//! `chump-github-cache-cli` — Phase 1 of INFRA-1999.
//!
//! Matches the bash `cache_*` helper surface 1:1:
//!
//! ```text
//! chump-github-cache-cli lookup-pr <N>         → JSON row to stdout
//! chump-github-cache-cli lookup-checks <SHA>   → `name\tstatus\tconclusion` per row
//! chump-github-cache-cli query-open-prs        → `number\ttitle\thead_ref` per row
//! chump-github-cache-cli query-open-prs-by-title <SUBSTR>
//! chump-github-cache-cli query-behind-prs      → one number per line
//! chump-github-cache-cli refresh-open-prs      → Phase 1 stub, prints 0
//! ```
//!
//! Selected by the bash shim at the top of
//! `scripts/coord/lib/github_cache.sh` when `CHUMP_GITHUB_CACHE_RUST=1`.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

use chump_github_cache::{CacheError, GithubCache, SqliteCache};

#[derive(Debug, Parser)]
#[command(
    name = "chump-github-cache-cli",
    about = "Reader-side CLI for .chump/github_cache.db (INFRA-1999 Phase 1)"
)]
struct Cli {
    /// Override the cache DB path (default: $CHUMP_CACHE_DB or
    /// `<repo_root>/.chump/github_cache.db`).
    #[arg(long, global = true)]
    db: Option<PathBuf>,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Debug, Subcommand)]
enum Cmd {
    /// Look up one PR by number; prints the cached raw payload JSON.
    LookupPr {
        /// PR number.
        number: u64,
    },
    /// Look up check_runs for one head SHA.
    LookupChecks {
        /// Head SHA.
        head_sha: String,
    },
    /// List open PRs as `number\ttitle\thead_ref` per row, DESC by number.
    QueryOpenPrs,
    /// List open PRs whose title contains <substr> (case-insensitive).
    QueryOpenPrsByTitle {
        /// Substring (need not be escaped — parameter-bound).
        substring: String,
    },
    /// List PR numbers in BEHIND + auto_merge_enabled state.
    QueryBehindPrs,
    /// Phase 1 stub: bulk-refill loop deferred. Prints `0`.
    RefreshOpenPrs,
}

fn resolve_db_path(arg: Option<PathBuf>) -> PathBuf {
    if let Some(p) = arg {
        return p;
    }
    if let Ok(p) = std::env::var("CHUMP_CACHE_DB") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    // Fall back: try `git rev-parse --show-toplevel` then append .chump.
    let root = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_else(|| ".".to_string());
    PathBuf::from(root).join(".chump").join("github_cache.db")
}

fn main() -> ExitCode {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .try_init();

    let cli = Cli::parse();
    let db = resolve_db_path(cli.db);
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(err) => {
            eprintln!("[chump-github-cache-cli] runtime init failed: {err}");
            return ExitCode::from(1);
        }
    };

    rt.block_on(async move {
        let cache = match SqliteCache::open(&db) {
            Ok(c) => c,
            Err(err) => {
                eprintln!(
                    "[chump-github-cache-cli] cache open failed ({}): {err}",
                    db.display()
                );
                return ExitCode::from(1);
            }
        };
        match dispatch(&cache, cli.cmd).await {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("[chump-github-cache-cli] {err}");
                ExitCode::from(1)
            }
        }
    })
}

async fn dispatch(cache: &SqliteCache, cmd: Cmd) -> Result<(), CacheError> {
    match cmd {
        Cmd::LookupPr { number } => {
            if let Some(pr) = cache.lookup_pr(number).await? {
                // Bash helper prints raw_payload_json on stdout. Fall back
                // to a structured JSON of our typed row if raw is missing.
                if let Some(raw) = pr.raw_payload_json.as_deref() {
                    print!("{raw}");
                } else {
                    println!("{}", serde_json::to_string(&pr)?);
                }
            }
        }
        Cmd::LookupChecks { head_sha } => {
            let rows = cache.lookup_checks(&head_sha).await?;
            for r in rows {
                println!(
                    "{name}\t{status}\t{conclusion}",
                    name = r.name,
                    status = r.status.as_deref().unwrap_or(""),
                    conclusion = r.conclusion.as_deref().unwrap_or(""),
                );
            }
        }
        Cmd::QueryOpenPrs => {
            let rows = cache.query_open_prs().await?;
            for r in rows {
                println!("{}\t{}\t{}", r.number, r.title, r.head_ref);
            }
        }
        Cmd::QueryOpenPrsByTitle { substring } => {
            let rows = cache.query_open_prs_by_title(&substring).await?;
            for r in rows {
                println!("{}\t{}\t{}", r.number, r.title, r.head_ref);
            }
        }
        Cmd::QueryBehindPrs => {
            let rows = cache.query_behind_prs().await?;
            for n in rows {
                println!("{}", n);
            }
        }
        Cmd::RefreshOpenPrs => {
            // Phase 1 stub: real REST bulk refill is deferred to a
            // follow-up sub-gap. Print 0 (matches the bash helper's
            // exit-stdout when it has nothing to refill).
            println!("0");
        }
    }
    Ok(())
}
