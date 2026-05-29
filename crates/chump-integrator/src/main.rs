//! chump-integrator binary entry-point.
//!
//! Usage:
//!   chump-integrator [--repo-root <path>] [--dry-run-log <path>] [--once]
//!
//! Flags:
//!   --repo-root   Path to chump repo root (default: CWD)
//!   --dry-run-log Override dry-run log path (default: ~/.chump/integrator-dry-run.log)
//!   --once        Run a single cycle then exit (useful for cron / CI smoke tests)
//!
//! All env knobs (CHUMP_INTEGRATOR_*) are read by IntegratorConfig::from_env().

use anyhow::{Context, Result};
use chump_integrator::IntegratorDaemon;
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mut repo_root: Option<PathBuf> = None;
    let mut dry_run_log: Option<PathBuf> = None;
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

    if once {
        daemon.run_cycle().await?;
    } else {
        daemon.run().await?;
    }

    Ok(())
}
