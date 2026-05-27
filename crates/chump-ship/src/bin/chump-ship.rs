//! `chump-ship` — CLI entry for the Phase 2 ship executor (INFRA-2001).
//!
//! Args mirror the subset of `scripts/coord/bot-merge.sh` needed for
//! the `--mode manual` happy path:
//!
//!   chump-ship --gap <GAP-ID> [--mode manual|bot-merge] [--branch <BRANCH>]
//!              [--base <BRANCH>] [--commit-message <STR>] [--dry-run]
//!              [--repo-root <PATH>]
//!
//! Exits 0 on success and prints the [`ShipReceipt`] to stdout as JSON.
//! Exits 1 on any [`ShipError`] (diagnostic to stderr).
//!
//! Invocation contract: the bash shim at the top of
//! `scripts/coord/bot-merge.sh` exec's this binary IFF
//! `CHUMP_SHIP_RUST=1` AND `--mode manual` (Phase 1 default).
//! Otherwise the legacy 3044 LOC bash body runs unchanged.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;

use chump_ship::bot_merge::BotMergePath;
use chump_ship::manual_ship::ManualShipPath;
use chump_ship::ship::{Ship, ShipError, ShipIntent};

#[derive(Parser, Debug)]
#[command(
    name = "chump-ship",
    about = "Chump ship pipeline executor (INFRA-2001 Phase 2)",
    version
)]
struct Args {
    /// Gap id this ship is for (e.g. INFRA-2001). Required.
    #[arg(long)]
    gap: String,

    /// Ship mode: manual (default) or bot-merge (stubbed in Phase 1).
    #[arg(long, default_value = "manual")]
    mode: ShipModeArg,

    /// Local branch to push. Default: HEAD ref name (resolved at runtime).
    #[arg(long)]
    branch: Option<String>,

    /// PR base branch. Default: main.
    #[arg(long, default_value = "main")]
    base: String,

    /// Commit message subject + PR title. Default: synthesized from gap.
    #[arg(long)]
    commit_message: Option<String>,

    /// Session id used for the single-instance socket bind. Default: env
    /// var `CHUMP_SESSION_ID` or a synthesized PID-based id.
    #[arg(long)]
    session_id: Option<String>,

    /// Bot worker session id (only used when --mode bot-merge).
    #[arg(long)]
    bot_session_id: Option<String>,

    /// Repo root for subprocess `git` + `gh`. Default: cwd.
    #[arg(long)]
    repo_root: Option<PathBuf>,

    /// Skip push + PR-create + arm-auto-merge; emit a synthesized
    /// receipt. Smoke tests use this.
    #[arg(long, default_value_t = false)]
    dry_run: bool,

    /// Auto-merge flag (Phase 1 default ON for parity with bash callsite).
    /// Reserved for future toggling; Phase 1 always arms when push lands.
    #[arg(long, default_value_t = true)]
    auto_merge: bool,
}

#[derive(clap::ValueEnum, Clone, Debug)]
enum ShipModeArg {
    Manual,
    BotMerge,
}

#[tokio::main]
async fn main() -> ExitCode {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .try_init();

    let args = Args::parse();
    match run(args).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("[chump-ship] {err}");
            ExitCode::from(1)
        }
    }
}

async fn run(args: Args) -> Result<(), ShipError> {
    let repo_root = args
        .repo_root
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));

    // Resolve branch: explicit > git HEAD ref name.
    let branch = match args.branch {
        Some(b) => b,
        None => resolve_head_branch(&repo_root).unwrap_or_else(|| "HEAD".to_string()),
    };

    let session_id = args.session_id.unwrap_or_else(|| {
        std::env::var("CHUMP_SESSION_ID")
            .unwrap_or_else(|_| format!("chump-ship-{}", std::process::id()))
    });

    let commit_message = args
        .commit_message
        .unwrap_or_else(|| format!("feat({}): automated ship via chump-ship", args.gap));

    let intent = ShipIntent::owned(
        args.gap.clone(),
        branch.clone(),
        args.base.clone(),
        commit_message,
        session_id.clone(),
    );

    let receipt = match args.mode {
        ShipModeArg::Manual => {
            let shipper = ManualShipPath::new(intent, &repo_root, args.dry_run)?;
            tracing::info!(
                gap = %args.gap,
                branch = %branch,
                base = %args.base,
                dry_run = args.dry_run,
                "chump-ship manual starting"
            );
            shipper.ship().await?
        }
        ShipModeArg::BotMerge => {
            let bot_session = args
                .bot_session_id
                .clone()
                .unwrap_or_else(|| session_id.clone());
            let shipper = BotMergePath::new(intent, &repo_root, bot_session)?;
            tracing::info!(
                gap = %args.gap,
                "chump-ship bot-merge starting (STUB in Phase 1)"
            );
            shipper.ship().await?
        }
    };

    // Print the receipt to stdout as JSON for downstream consumers.
    let json = serde_json::to_string_pretty(&receipt)?;
    println!("{json}");
    Ok(())
}

fn resolve_head_branch(repo_root: &std::path::Path) -> Option<String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() || s == "HEAD" {
        None
    } else {
        Some(s)
    }
}
