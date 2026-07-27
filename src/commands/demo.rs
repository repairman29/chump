//! INFRA-2391: `chump demo` — wires the META-072 chump-demo crate (formerly
//! shelfware: a standalone `chump-demo` binary nobody invoked) as a real
//! `chump` subcommand instead of leaving it undiscoverable.
//!
//! Implementation: exec the sibling `chump-demo` binary built by the same
//! cargo workspace (it lives next to the `chump` binary in the same
//! target/<profile>/ directory), forwarding all args and the exit code.
//! This keeps chump-demo's existing clap parser (`chump-demo --help` /
//! `--dry-run` / `--seed` / `--duration` all keep working unchanged) while
//! giving it a normal `chump demo ...` entry point.
//!
//! This resolution itself emits a one-shot audit event (no daemon owns
//! this kind — it's appended once by whichever agent ships the fix):
//! # scanner-anchor: "kind":"shelfware_resolved"

use std::process::Command;

fn sibling_binary_path() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let candidate = dir.join(if cfg!(windows) {
        "chump-demo.exe"
    } else {
        "chump-demo"
    });
    if candidate.is_file() {
        Some(candidate)
    } else {
        None
    }
}

pub fn run(args: &[String]) -> i32 {
    let bin = sibling_binary_path().or_else(|| which_on_path("chump-demo"));
    let Some(bin) = bin else {
        eprintln!(
            "error: chump-demo binary not found next to `chump` or on PATH.\n\
             Build it with: cargo build -p chump-demo"
        );
        return 1;
    };

    match Command::new(&bin).args(args).status() {
        Ok(status) => status.code().unwrap_or(1),
        Err(e) => {
            eprintln!("error: failed to exec {}: {e}", bin.display());
            1
        }
    }
}

fn which_on_path(name: &str) -> Option<std::path::PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|p| p.join(name))
        .find(|p| p.is_file())
}
