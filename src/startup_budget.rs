//! INFRA-3784 (INFRA-1809 slice): startup wallclock budget + timeout
//! enforcement. Wraps the rest of `main()` (everything after arg parsing) in
//! a `tokio::time::timeout` so a hung startup path (deadlocked mutex, network
//! call that never returns, etc.) fails loud with a diagnostic dump instead
//! of hanging the CLI forever.

use std::time::{Duration, Instant};

/// Default startup wallclock budget in milliseconds. Generous enough that no
/// real startup path should ever hit it under normal conditions.
pub const DEFAULT_STARTUP_TIMEOUT_MS: u64 = 5000;

/// Reads `CHUMP_STARTUP_TIMEOUT_MS`, defaulting to `DEFAULT_STARTUP_TIMEOUT_MS`
/// on unset or unparseable values.
pub fn startup_timeout_ms() -> u64 {
    std::env::var("CHUMP_STARTUP_TIMEOUT_MS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(DEFAULT_STARTUP_TIMEOUT_MS)
}

/// Runs `startup` under the configured wallclock budget. On timeout, dumps
/// tokio runtime + memory_db + subsystem diagnostics to stderr, emits
/// `kind=chump_startup_timeout` to ambient.jsonl, and exits the process with
/// code 4 (this branch never returns).
pub async fn run_with_budget<F, T>(args: &[String], startup: F) -> T
where
    F: std::future::Future<Output = T>,
{
    let timeout_ms = startup_timeout_ms();
    let start = Instant::now();
    // Force at least one scheduler tick before dispatching into `startup` so
    // the timeout future gets a chance to observe an already-elapsed
    // deadline even when `startup` never itself awaits (e.g. `--version`).
    tokio::task::yield_now().await;

    match tokio::time::timeout(Duration::from_millis(timeout_ms), startup).await {
        Ok(v) => v,
        Err(_) => {
            let elapsed_ms = start.elapsed().as_millis() as u64;
            dump_timeout_diagnostics(args, elapsed_ms);
            std::process::exit(4);
        }
    }
}

fn dump_timeout_diagnostics(args: &[String], elapsed_ms: u64) {
    let cmd = args.first().map(String::as_str).unwrap_or("chump");
    let rt_status = tokio::runtime::Handle::try_current()
        .map(|h| format!("active, handle={:?}", h.id()))
        .unwrap_or_else(|_| "no current runtime handle".to_string());
    let memory_db_state = if crate::memory_db::db_available() {
        "available"
    } else {
        "unavailable"
    };
    // Best-effort guess until a later INFRA-1809 slice adds per-subsystem
    // instrumentation; still useful as a triage starting point.
    let suspected_subsystem = if args.len() > 1 {
        args[1].as_str()
    } else {
        "arg-parsing"
    };

    eprintln!("chump: startup wallclock budget exceeded ({elapsed_ms}ms elapsed, cmd={cmd})");
    eprintln!("  args: {args:?}");
    eprintln!("  tokio runtime: {rt_status}");
    eprintln!("  memory_db: {memory_db_state}");
    eprintln!("  suspected_subsystem: {suspected_subsystem}");

    // scanner-anchor: "kind":"chump_startup_timeout"
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "chump_startup_timeout".to_string(),
        source: Some("startup_budget".to_string()),
        fields: vec![
            ("cmd".to_string(), cmd.to_string()),
            ("args".to_string(), format!("{args:?}")),
            ("elapsed_ms".to_string(), elapsed_ms.to_string()),
            (
                "suspected_subsystem".to_string(),
                suspected_subsystem.to_string(),
            ),
        ],
        ..Default::default()
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_timeout_when_unset() {
        // SAFETY: single-threaded test process env mutation, restored after.
        unsafe { std::env::remove_var("CHUMP_STARTUP_TIMEOUT_MS") };
        assert_eq!(startup_timeout_ms(), DEFAULT_STARTUP_TIMEOUT_MS);
    }

    #[test]
    fn parses_valid_override() {
        unsafe { std::env::set_var("CHUMP_STARTUP_TIMEOUT_MS", "1234") };
        assert_eq!(startup_timeout_ms(), 1234);
        unsafe { std::env::remove_var("CHUMP_STARTUP_TIMEOUT_MS") };
    }

    #[test]
    fn falls_back_on_garbage_value() {
        unsafe { std::env::set_var("CHUMP_STARTUP_TIMEOUT_MS", "not-a-number") };
        assert_eq!(startup_timeout_ms(), DEFAULT_STARTUP_TIMEOUT_MS);
        unsafe { std::env::remove_var("CHUMP_STARTUP_TIMEOUT_MS") };
    }

    #[tokio::test]
    async fn fast_startup_completes_normally() {
        unsafe { std::env::set_var("CHUMP_STARTUP_TIMEOUT_MS", "5000") };
        let args = vec!["chump".to_string(), "--version".to_string()];
        let result = run_with_budget(&args, async { 42 }).await;
        assert_eq!(result, 42);
        unsafe { std::env::remove_var("CHUMP_STARTUP_TIMEOUT_MS") };
    }
}
