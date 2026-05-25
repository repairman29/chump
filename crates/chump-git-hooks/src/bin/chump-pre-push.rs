//! `chump-pre-push` — Rust pre-push hook entry (Phase 1 of INFRA-1997).
//!
//! Invocation contract matches git's pre-push hook:
//! - argv[1]: remote name (e.g. `origin`)
//! - argv[2]: remote URL (unused)
//! - stdin: one line per ref `<local_ref> <local_sha> <remote_ref> <remote_sha>`
//!
//! Exits 0 on Pass, 1 on Block. Diagnostic goes to stderr.
//!
//! The shim in `scripts/git-hooks/pre-push` exec's this binary IFF
//! `CHUMP_PREPUSH_RUST=1`; otherwise the legacy bash hook runs.

use std::process::ExitCode;

use chump_git_hooks::{phase1_chain, read_stdin_to_string, run_hooks, HookContext, HookOutcome};

fn main() -> ExitCode {
    // Tracing: stderr-only, controlled by RUST_LOG (default WARN).
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .try_init();

    let args: Vec<String> = std::env::args().collect();
    let remote_name = args.get(1).cloned().unwrap_or_else(|| "origin".to_string());

    let stdin_buf = match read_stdin_to_string() {
        Ok(s) => s,
        Err(err) => {
            eprintln!("[chump-pre-push] failed to read stdin: {err}");
            return ExitCode::from(1);
        }
    };

    let ctx = match HookContext::new_from_stdin(remote_name, &stdin_buf) {
        Ok(c) => c,
        Err(err) => {
            eprintln!("[chump-pre-push] context init failed: {err}");
            return ExitCode::from(1);
        }
    };

    tracing::info!(
        repo_root = %ctx.repo_root.display(),
        refspecs = ctx.refspecs.len(),
        remote = %ctx.remote_name,
        "chump-pre-push starting"
    );

    let chain = phase1_chain();
    match run_hooks(&ctx, &chain) {
        Ok(HookOutcome::Pass) => {
            tracing::info!("all guards passed");
            ExitCode::SUCCESS
        }
        Ok(HookOutcome::Skipped { reason }) => {
            tracing::info!(%reason, "hook chain ended in skipped state");
            ExitCode::SUCCESS
        }
        Ok(HookOutcome::Block(reason)) => {
            eprintln!();
            eprintln!("[chump-pre-push] BLOCKED ({code}):", code = reason.code);
            eprintln!("{}", reason.diagnostic);
            eprintln!();
            ExitCode::from(1)
        }
        Err(err) => {
            eprintln!("[chump-pre-push] hook error: {err}");
            ExitCode::from(1)
        }
    }
}
