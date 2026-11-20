//! Shared CLI parser and runner for `chump-ship` and `chump ship` (Milestone 3).

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use clap::Parser;

use crate::bot_merge::BotMergePath;
use crate::gate_guard::check_gate_arm_refused;
use crate::manual_ship::{resolve_worktree_and_branch, ManualShipPath};
use crate::ship::{Ship, ShipError, ShipIntent};

/// CLI arguments for `chump-ship` / `chump ship` (superset-compatible with
/// legacy `scripts/coord/bot-merge.sh` flags).
#[derive(Parser, Debug)]
#[command(
    name = "chump-ship",
    about = "Cross-platform Chump ship & bot-merge pipeline executor",
    version
)]
pub struct ShipCliArgs {
    /// Gap ID(s) this ship is for (e.g. INFRA-2001). Repeatable or space-separated.
    #[arg(long = "gap")]
    pub gaps: Vec<String>,

    /// Ship mode: `manual` or `bot-merge`.
    #[arg(long, default_value = "bot-merge")]
    pub mode: ShipModeCliArg,

    /// Local branch to push. Default: active worktree HEAD branch.
    #[arg(long)]
    pub branch: Option<String>,

    /// PR base branch (default: `main`, overridden if `--stack-on` is provided).
    #[arg(long, default_value = "main")]
    pub base: String,

    /// Stack PR onto another branch/gap base ref.
    #[arg(long)]
    pub stack_on: Option<String>,

    /// Commit message subject + PR title. Default: HEAD commit subject or synthesized.
    #[arg(long)]
    pub commit_message: Option<String>,

    /// Session id used for single-instance lock binding.
    #[arg(long)]
    pub session_id: Option<String>,

    /// Worker bot session id (used when `--mode bot-merge`).
    #[arg(long)]
    pub bot_session_id: Option<String>,

    /// Repository / worktree root. Default: resolved from invoking cwd.
    #[arg(long)]
    pub repo_root: Option<PathBuf>,

    /// Print planned git/gh actions and emit a synthesized receipt without mutating remotes.
    #[arg(long, default_value_t = false)]
    pub dry_run: bool,

    /// CREDIBLE-1607 / CREDIBLE-1576: Explicitly request GitHub auto-merge arming
    /// (subject to `arm_policy` and `gate_guard` refusal).
    #[arg(long, default_value_t = false)]
    pub auto_merge: bool,

    /// CREDIBLE-1576 standalone gate check: evaluate whether `--auto-merge` would
    /// be refused on `<base>...HEAD` and exit (0 = allowed, 2 = refused) without shipping.
    #[arg(long, default_value_t = false)]
    pub gate_arm_check: bool,

    // ── Legacy bot-merge.sh compatibility flags (accepted cleanly) ───────────
    /// Compatibility flag from `bot-merge.sh`: skip local cargo test.
    #[arg(long, default_value_t = false)]
    pub skip_tests: bool,

    /// Compatibility flag from `bot-merge.sh`: fast pre-flight mode.
    #[arg(long, default_value_t = false)]
    pub fast: bool,

    /// Compatibility flag from `bot-merge.sh`: lean-on-CI mode.
    #[arg(long, default_value_t = false)]
    pub no_local_build: bool,

    /// Compatibility flag from `bot-merge.sh`: disable custom merge drivers.
    #[arg(long, default_value_t = false)]
    pub no_merge_driver: bool,

    /// Compatibility flag from `bot-merge.sh`: risk lane tag.
    #[arg(long)]
    pub lane: Option<String>,

    /// Compatibility flag from `bot-merge.sh`: branch prefix override.
    #[arg(long)]
    pub branch_prefix: Option<String>,

    /// Compatibility flag from `bot-merge.sh`: PR body template path.
    #[arg(long)]
    pub pr_template: Option<PathBuf>,

    /// Compatibility flag from `bot-merge.sh`: comma-separated required checks.
    #[arg(long)]
    pub required_checks: Option<String>,
}

/// CLI enum selecting `ManualShipPath` or `BotMergePath`.
#[derive(clap::ValueEnum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShipModeCliArg {
    Manual,
    BotMerge,
}

/// Run the `chump-ship` CLI from an explicit argument slice (including `argv[0]`)
/// and return the desired process exit code (`0` = success, `2` = gate-arm-check
/// refused, `1` = error).
pub async fn run_from_itr<I, T>(itr: I) -> u8
where
    I: IntoIterator<Item = T>,
    T: Into<OsString> + Clone,
{
    let args = match ShipCliArgs::try_parse_from(itr) {
        Ok(a) => a,
        Err(e) => {
            let code = if e.use_stderr() { 2 } else { 0 };
            let _ = e.print();
            return code;
        }
    };
    match execute_cli(args).await {
        Ok(code) => code,
        Err(err) => {
            eprintln!("[chump-ship] error: {err}");
            1
        }
    }
}

/// Execute parsed [`ShipCliArgs`] and return process exit code.
pub async fn execute_cli(args: ShipCliArgs) -> Result<u8, ShipError> {
    let invoking_cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let (repo_root, branch) = match resolve_worktree_and_branch(
        &invoking_cwd,
        args.repo_root.as_deref(),
        args.branch.as_deref(),
    ) {
        Ok((wt, br)) => (wt, br),
        Err(_) => {
            let wt = args.repo_root.clone().unwrap_or(invoking_cwd);
            let br = args
                .branch
                .clone()
                .unwrap_or_else(|| resolve_head_branch(&wt).unwrap_or_else(|| "HEAD".to_string()));
            (wt, br)
        }
    };

    let base = args
        .stack_on
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(&args.base)
        .to_string();

    if args.gate_arm_check {
        return match check_gate_arm_refused(&repo_root, &base, args.auto_merge) {
            Ok(()) => Ok(0),
            Err(refusal) => {
                eprintln!("{refusal}");
                Ok(2)
            }
        };
    }

    let primary_gap = args
        .gaps
        .iter()
        .flat_map(|g| g.split_whitespace())
        .next()
        .map(ToOwned::to_owned)
        .or_else(|| infer_gap_from_branch(&branch))
        .unwrap_or_else(|| "UNSPECIFIED".to_string());

    let session_id = args.session_id.unwrap_or_else(|| {
        std::env::var("CHUMP_SESSION_ID")
            .unwrap_or_else(|_| format!("chump-ship-{}", std::process::id()))
    });

    let commit_message = args
        .commit_message
        .or_else(|| resolve_head_subject(&repo_root))
        .unwrap_or_else(|| format!("feat({primary_gap}): automated ship via chump-ship"));

    let intent = ShipIntent::owned(
        primary_gap.clone(),
        branch.clone(),
        base.clone(),
        commit_message,
        session_id.clone(),
    );

    let receipt = match args.mode {
        ShipModeCliArg::Manual => {
            let shipper = ManualShipPath::new(intent, &repo_root, args.dry_run)?
                .with_auto_merge(args.auto_merge);
            shipper.ship().await?
        }
        ShipModeCliArg::BotMerge => {
            let bot_session = args
                .bot_session_id
                .unwrap_or_else(|| format!("{session_id}-{primary_gap}"));
            let shipper = BotMergePath::new(intent, &repo_root, bot_session)?
                .with_dry_run(args.dry_run)
                .with_auto_merge(args.auto_merge);
            shipper.ship().await?
        }
    };

    let json = serde_json::to_string_pretty(&receipt)?;
    println!("{json}");
    Ok(0)
}

fn infer_gap_from_branch(branch: &str) -> Option<String> {
    let tail = branch.rsplit('/').next().unwrap_or(branch);
    let mut parts = tail.split('-');
    let p1 = parts.next()?;
    let p2 = parts.next()?;
    if p1.chars().all(|c| c.is_ascii_alphabetic())
        && !p1.is_empty()
        && p2.chars().all(|c| c.is_ascii_alphanumeric())
        && p2.chars().any(|c| c.is_ascii_digit())
    {
        Some(format!(
            "{}-{}",
            p1.to_ascii_uppercase(),
            p2.to_ascii_uppercase()
        ))
    } else {
        None
    }
}

fn resolve_head_branch(repo_root: &Path) -> Option<String> {
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

fn resolve_head_subject(repo_root: &Path) -> Option<String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["log", "-1", "--format=%s"])
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
