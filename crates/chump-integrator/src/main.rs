//! chump-integrator binary entry-point.
//!
//! Usage:
//!   chump-integrator [--repo-root <path>] [--dry-run-log <path>] [--sampling-pct N] [--once]
//!
//! Flags:
//!   --repo-root    Path to chump repo root (default: CWD)
//!   --dry-run-log  Override dry-run log path (default: ~/.chump/integrator-dry-run.log)
//!   --sampling-pct Phase 2 sampling rate 0-100 (env CHUMP_INTEGRATOR_SAMPLING_PCT wins over CLI)
//!   --once         Run a single cycle then exit (useful for cron / CI smoke tests)
//!
//! All env knobs (CHUMP_INTEGRATOR_*) are read by IntegratorConfig::from_env().
//! Environment variable CHUMP_INTEGRATOR_SAMPLING_PCT takes precedence over --sampling-pct.

use anyhow::{Context, Result};
use chump_integrator::IntegratorDaemon;
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mut repo_root: Option<PathBuf> = None;
    let mut dry_run_log: Option<PathBuf> = None;
    let mut sampling_pct_cli: Option<u8> = None;
    let mut once = false;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--repo-root" => {
                repo_root = Some(PathBuf::from(
                    args.get(i + 1)
                        .context("--repo-root requires a path argument")?,
                ));
                i += 2;
            }
            "--dry-run-log" => {
                dry_run_log = Some(PathBuf::from(
                    args.get(i + 1)
                        .context("--dry-run-log requires a path argument")?,
                ));
                i += 2;
            }
            "--sampling-pct" => {
                let raw = args
                    .get(i + 1)
                    .context("--sampling-pct requires an integer argument")?;
                let v: u8 = raw
                    .parse()
                    .with_context(|| format!("--sampling-pct must be 0-100, got '{raw}'"))?;
                sampling_pct_cli = Some(v.min(100));
                i += 2;
            }
            "--once" => {
                once = true;
                i += 1;
            }
            other => {
                eprintln!("unknown argument: {other}");
                std::process::exit(1);
            }
        }
    }

    let root = repo_root.unwrap_or_else(|| std::env::current_dir().expect("cannot determine CWD"));

    let mut daemon = IntegratorDaemon::new(root)
        .await
        .context("initialising IntegratorDaemon")?;

    if let Some(log_path) = dry_run_log {
        daemon.dry_run_log = log_path;
    }

    // Apply CLI --sampling-pct only when env var is not set (env wins).
    if let Some(cli_pct) = sampling_pct_cli {
        if std::env::var("CHUMP_INTEGRATOR_SAMPLING_PCT").is_err() {
            daemon.config.sampling_pct = cli_pct;
        } else {
            eprintln!(
                "[integrator] --sampling-pct ignored: CHUMP_INTEGRATOR_SAMPLING_PCT env is set"
            );
        }
    }

    if once {
        daemon.run_cycle().await?;
    } else {
        daemon.run().await?;
    }

    Ok(())
}
