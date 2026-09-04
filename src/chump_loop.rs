//! EFFECTIVE-1138 (EFFECTIVE-178 slice): `chump loop <cmd> --interval N
//! [--max-iters M] [--json]` — ephemeral scheduler.
//!
//! Re-runs an arbitrary command every N seconds, with an optional
//! iteration cap. Harness-agnostic: no dependency on Claude Code or
//! launchd — the process itself is the scheduler, so it can be invoked
//! from any shell / any CI runner / any harness. For fleet-durable
//! scheduling (must survive the invoking session closing) use
//! `chump cron install` instead; this is for session-bound repeats.
//!
//! Terminates gracefully on SIGINT/SIGTERM: the in-flight iteration is
//! allowed to finish, then the loop stops before starting the next one
//! (no sleep-interrupt kill of a running child).
//!
//! `--json` emits one JSON line per iteration to stdout:
//!   {"iteration":1,"cmd":"echo hi","exit_code":0,"started_at":"...","ended_at":"...","duration_ms":12}

use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

static TERMINATE: AtomicBool = AtomicBool::new(false);

extern "C" fn handle_signal(_sig: libc::c_int) {
    TERMINATE.store(true, Ordering::SeqCst);
}

fn install_signal_handlers() {
    unsafe {
        libc::signal(libc::SIGINT, handle_signal as libc::sighandler_t);
        libc::signal(libc::SIGTERM, handle_signal as libc::sighandler_t);
    }
}

fn print_usage() {
    eprintln!(
        "Usage: chump loop <cmd> [args...] --interval <seconds> [--max-iters <n>] [--json]\n\n\
         Runs <cmd> every <interval> seconds until --max-iters is reached (default:\n\
         unbounded) or SIGINT/SIGTERM is received. Works independently of Claude or\n\
         launchd; safe to invoke from any harness or shell.\n\n\
         Examples:\n  \
         chump loop -- echo hi --interval 5\n  \
         chump loop chump gap list --status open --interval 30 --max-iters 10 --json"
    );
}

struct ParsedArgs {
    cmd: Vec<String>,
    interval_secs: u64,
    max_iters: Option<u64>,
    json: bool,
}

fn parse_args(args: &[String]) -> Result<ParsedArgs, String> {
    let mut cmd: Vec<String> = Vec::new();
    let mut interval_secs: Option<u64> = None;
    let mut max_iters: Option<u64> = None;
    let mut json = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--interval" => {
                let val = args
                    .get(i + 1)
                    .ok_or_else(|| "--interval requires a value".to_string())?;
                interval_secs = Some(
                    val.parse::<u64>()
                        .map_err(|_| format!("--interval value '{val}' is not a valid number of seconds"))?,
                );
                i += 2;
            }
            "--max-iters" => {
                let val = args
                    .get(i + 1)
                    .ok_or_else(|| "--max-iters requires a value".to_string())?;
                max_iters = Some(
                    val.parse::<u64>()
                        .map_err(|_| format!("--max-iters value '{val}' is not a valid integer"))?,
                );
                i += 2;
            }
            "--json" => {
                json = true;
                i += 1;
            }
            "--" => {
                // Explicit separator: everything after belongs to the command,
                // even if it looks like a --flag chump loop would otherwise eat.
                cmd.extend(args[i + 1..].iter().cloned());
                i = args.len();
            }
            other => {
                cmd.push(other.to_string());
                i += 1;
            }
        }
    }

    let interval_secs = interval_secs.ok_or_else(|| "--interval <seconds> is required".to_string())?;
    if interval_secs == 0 {
        return Err("--interval must be greater than 0".to_string());
    }
    if cmd.is_empty() {
        return Err("no <cmd> given to run".to_string());
    }

    Ok(ParsedArgs {
        cmd,
        interval_secs,
        max_iters,
        json,
    })
}

fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339()
}

pub fn run(args: &[String]) -> i32 {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        return 0;
    }

    let parsed = match parse_args(args) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("chump loop: {e}");
            print_usage();
            return 2;
        }
    };

    install_signal_handlers();

    let mut iteration: u64 = 0;
    loop {
        if TERMINATE.load(Ordering::SeqCst) {
            break;
        }
        if let Some(max) = parsed.max_iters {
            if iteration >= max {
                break;
            }
        }
        iteration += 1;

        let started_at = now_rfc3339();
        let iter_start = Instant::now();
        let status = Command::new(&parsed.cmd[0]).args(&parsed.cmd[1..]).status();
        let duration_ms = iter_start.elapsed().as_millis();
        let ended_at = now_rfc3339();

        let exit_code: i64 = match &status {
            Ok(s) => s.code().map(i64::from).unwrap_or(-1),
            Err(e) => {
                eprintln!("chump loop: failed to spawn '{}': {e}", parsed.cmd[0]);
                -1
            }
        };

        if parsed.json {
            let line = serde_json::json!({
                "iteration": iteration,
                "cmd": parsed.cmd.join(" "),
                "exit_code": exit_code,
                "started_at": started_at,
                "ended_at": ended_at,
                "duration_ms": duration_ms,
            });
            println!("{line}");
        } else {
            println!(
                "[chump loop] iteration {iteration} exit={exit_code} duration={duration_ms}ms ({started_at})"
            );
        }

        if TERMINATE.load(Ordering::SeqCst) {
            break;
        }
        if let Some(max) = parsed.max_iters {
            if iteration >= max {
                break;
            }
        }

        // Sleep in short slices so SIGINT/SIGTERM during the wait is honored
        // promptly instead of blocking for up to the full interval.
        let sleep_slice = Duration::from_millis(200);
        let mut remaining = Duration::from_secs(parsed.interval_secs);
        while remaining > Duration::ZERO {
            if TERMINATE.load(Ordering::SeqCst) {
                break;
            }
            let this_sleep = sleep_slice.min(remaining);
            std::thread::sleep(this_sleep);
            remaining = remaining.saturating_sub(this_sleep);
        }
    }

    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_basic_invocation() {
        let args: Vec<String> = ["echo", "hi", "--interval", "5"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let parsed = parse_args(&args).unwrap();
        assert_eq!(parsed.cmd, vec!["echo", "hi"]);
        assert_eq!(parsed.interval_secs, 5);
        assert_eq!(parsed.max_iters, None);
        assert!(!parsed.json);
    }

    #[test]
    fn parses_max_iters_and_json() {
        let args: Vec<String> = ["echo", "hi", "--interval", "1", "--max-iters", "3", "--json"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let parsed = parse_args(&args).unwrap();
        assert_eq!(parsed.max_iters, Some(3));
        assert!(parsed.json);
    }

    #[test]
    fn double_dash_separator_preserves_flag_like_cmd_args() {
        let args: Vec<String> = ["--interval", "5", "--", "echo", "--json"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let parsed = parse_args(&args).unwrap();
        assert_eq!(parsed.cmd, vec!["echo", "--json"]);
        assert_eq!(parsed.interval_secs, 5);
    }

    #[test]
    fn missing_interval_errors() {
        let args: Vec<String> = ["echo", "hi"].iter().map(|s| s.to_string()).collect();
        assert!(parse_args(&args).is_err());
    }

    #[test]
    fn missing_cmd_errors() {
        let args: Vec<String> = ["--interval", "5"].iter().map(|s| s.to_string()).collect();
        assert!(parse_args(&args).is_err());
    }

    #[test]
    fn zero_interval_errors() {
        let args: Vec<String> = ["echo", "--interval", "0"].iter().map(|s| s.to_string()).collect();
        assert!(parse_args(&args).is_err());
    }

    #[test]
    fn end_to_end_runs_and_stops_at_max_iters() {
        let args: Vec<String> = ["true", "--interval", "1", "--max-iters", "2"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(run(&args), 0);
    }
}
