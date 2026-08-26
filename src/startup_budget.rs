//! INFRA-3784 (INFRA-1809 slice): startup wallclock budget + timeout enforcement.
//!
//! Wraps the entire post-arg-parsing startup sequence of `fn main()` in a
//! `tokio::time::timeout`. If the budget (default 5000ms, override via
//! `CHUMP_STARTUP_TIMEOUT_MS`) is exceeded, dumps a diagnostic to stderr,
//! emits `kind=chump_startup_timeout` to ambient.jsonl, and exits 4. This is
//! the enforcement half of INFRA-1809 (chump CLI startup hangs) — the
//! bisect/lazy-init half is tracked separately.

use std::time::{Duration, Instant};

/// Default startup wallclock budget in milliseconds.
pub const DEFAULT_TIMEOUT_MS: u64 = 5000;

/// Reads `CHUMP_STARTUP_TIMEOUT_MS` (default [`DEFAULT_TIMEOUT_MS`]).
pub fn timeout_duration() -> Duration {
    let ms = std::env::var("CHUMP_STARTUP_TIMEOUT_MS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(DEFAULT_TIMEOUT_MS);
    Duration::from_millis(ms)
}

/// Dumps tokio runtime status, memory_db connection state, and active
/// subsystems to stderr; emits `kind=chump_startup_timeout` to
/// ambient.jsonl; and exits the process with code 4. Never returns.
pub fn handle_timeout(args: &[String], started_at: Instant, budget: Duration) -> ! {
    let elapsed_ms = started_at.elapsed().as_millis();
    let cmd = args.first().cloned().unwrap_or_default();
    let arg_str = args.get(1..).map(|a| a.join(" ")).unwrap_or_default();
    let suspected_subsystem = "unknown"; // INFRA-1809 bisect (tokio runtime init / memory_db pool) is a separate slice

    eprintln!(
        "[chump_startup_timeout] startup exceeded {}ms budget ({}ms elapsed)",
        budget.as_millis(),
        elapsed_ms
    );
    eprintln!("[chump_startup_timeout] cmd: {cmd}");
    eprintln!("[chump_startup_timeout] args: {arg_str}");
    eprintln!(
        "[chump_startup_timeout] tokio runtime status: worker_threads={:?} (flavor=multi_thread via #[tokio::main])",
        std::thread::available_parallelism().ok()
    );
    eprintln!(
        "[chump_startup_timeout] memory_db connection state: unknown (pool not queried past this point in startup)"
    );
    eprintln!("[chump_startup_timeout] active subsystems: suspected={suspected_subsystem}");

    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "chump_startup_timeout".to_string(),
        source: Some("startup_budget".to_string()),
        fields: vec![
            ("cmd".to_string(), cmd),
            ("args".to_string(), arg_str),
            ("elapsed_ms".to_string(), elapsed_ms.to_string()),
            (
                "suspected_subsystem".to_string(),
                suspected_subsystem.to_string(),
            ),
        ],
        ..Default::default()
    });

    std::process::exit(4);
}
