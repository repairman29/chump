//! `ambient` — emit and tail structured telemetry on `.chump-locks/ambient.jsonl`.
//!
//! See `chump-ambient-cli` crate docs for the full contract. This binary is
//! the thinnest possible wrapper around [`chump_ambient_cli::ambient_emit::emit`]
//! and [`chump_ambient_cli::ambient_stream::locate_ambient`].

use anyhow::{anyhow, Result};
use chump_ambient_cli::ambient_emit::{emit, EmitArgs};
use chump_ambient_cli::ambient_stream::locate_ambient;
use std::path::PathBuf;

fn print_help() {
    eprintln!(
        "ambient — append-only structured telemetry on .chump-locks/ambient.jsonl\n\n\
         USAGE:\n\
           ambient emit <kind> [--gap ID] [--source S] [--harness H] [--field key=value]...\n\
                  Append a schema-valid JSON event.\n\n\
           ambient tail [--lines N] [--kind K] [--path PATH]\n\
                  Print recent events. Defaults: --lines 50, all kinds,\n\
                  auto-discovered ambient log path (walks up from CWD).\n\n\
           ambient --help | -h\n\
                  Show this message.\n\n\
         ENV:\n\
           CHUMP_AMBIENT_LOG    Override the ambient log path.\n\
           CHUMP_REPO/CHUMP_HOME  Override repo discovery (else `git rev-parse --show-toplevel`).\n\
           CHUMP_SESSION_ID     Override session ID (otherwise auto-resolved).\n\
           CHUMP_AGENT_HARNESS  Default harness when --harness not given."
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let rc = run(&args);
    std::process::exit(rc);
}

fn run(args: &[String]) -> i32 {
    let Some(sub) = args.get(1) else {
        print_help();
        return 2;
    };
    let result: Result<()> = match sub.as_str() {
        "emit" => EmitArgs::from_argv(args).and_then(|a| emit(&a).map(|_| ())),
        "tail" => run_tail(&args[2..]),
        "--help" | "-h" | "help" => {
            print_help();
            return 0;
        }
        other => {
            eprintln!("ambient: unknown subcommand '{other}'");
            print_help();
            return 2;
        }
    };
    match result {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("ambient: {e}");
            1
        }
    }
}

fn run_tail(args: &[String]) -> Result<()> {
    let mut lines: usize = 50;
    let mut kind_filter: Option<String> = None;
    let mut path_override: Option<PathBuf> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--lines" | "-n" => {
                lines = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow!("--lines needs a value"))?
                    .parse()
                    .map_err(|e| anyhow!("--lines must be a positive integer: {e}"))?;
                i += 2;
            }
            "--kind" => {
                kind_filter = Some(
                    args.get(i + 1)
                        .ok_or_else(|| anyhow!("--kind needs a value"))?
                        .clone(),
                );
                i += 2;
            }
            "--path" => {
                path_override = Some(PathBuf::from(
                    args.get(i + 1)
                        .ok_or_else(|| anyhow!("--path needs a value"))?,
                ));
                i += 2;
            }
            other => return Err(anyhow!("unknown flag for tail: {other}")),
        }
    }

    let path = path_override
        .or_else(|| std::env::var("CHUMP_AMBIENT_LOG").ok().map(PathBuf::from))
        .or_else(|| {
            let start = std::env::current_dir().ok()?;
            locate_ambient(&start)
        })
        .ok_or_else(|| {
            anyhow!(
                "could not find ambient.jsonl: pass --path, set CHUMP_AMBIENT_LOG, \
                 or run from inside a repo with .chump-locks/ambient.jsonl"
            )
        })?;

    let body =
        std::fs::read_to_string(&path).map_err(|e| anyhow!("read {}: {e}", path.display()))?;
    let all_lines: Vec<&str> = body.lines().collect();

    let filtered: Vec<&&str> = if let Some(ref k) = kind_filter {
        let kind_tag = format!("\"kind\":\"{k}\"");
        let event_tag = format!("\"event\":\"{k}\"");
        all_lines
            .iter()
            .filter(|line| line.contains(&kind_tag) || line.contains(&event_tag))
            .collect()
    } else {
        all_lines.iter().collect()
    };

    let start = filtered.len().saturating_sub(lines);
    for line in &filtered[start..] {
        println!("{}", line);
    }
    Ok(())
}
