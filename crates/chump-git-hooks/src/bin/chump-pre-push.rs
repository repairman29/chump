//! `chump-pre-push` — Cross-platform Rust `pre-push` hook binary.

use std::process::ExitCode;

use chump_git_hooks::{read_stdin_to_string, run_pre_push_cli};

fn main() -> ExitCode {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .try_init();

    let remote_name = std::env::args().nth(1);
    let stdin_buf = match read_stdin_to_string() {
        Ok(s) => s,
        Err(err) => {
            eprintln!("[chump-pre-push] failed to read stdin: {err}");
            return ExitCode::from(1);
        }
    };

    ExitCode::from(run_pre_push_cli(remote_name, &stdin_buf))
}
