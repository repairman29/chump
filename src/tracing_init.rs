//! Tracing bootstrap for `RUST_LOG` and `CHUMP_TRACING_*`. See `docs/SELF_IMPROVE_LOGGING.md`.

use std::fs::OpenOptions;
use std::path::PathBuf;
use std::sync::Mutex;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::Layer;
use tracing_subscriber::{fmt, EnvFilter, Registry};

fn env_truthy(name: &str) -> bool {
    std::env::var(name)
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// When `CHUMP_TRACING_FILE` is `1` / `true`, write to `logs/tracing.jsonl` under [`crate::repo_path::runtime_base`].
/// Otherwise treat the value as a path (absolute or relative to runtime base if not absolute).
fn resolve_tracing_file_path(raw: &str) -> Option<PathBuf> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let base = crate::repo_path::runtime_base();
    let path = if raw == "1" || raw.eq_ignore_ascii_case("true") {
        base.join("logs").join("tracing.jsonl")
    } else {
        let p = PathBuf::from(raw);
        if p.is_absolute() {
            p
        } else {
            base.join(p)
        }
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    Some(path)
}

/// Default filter when `RUST_LOG` is unset: informative for self-improve / debugging without full hyper noise.
/// Crate name is `rust_agent` (package `rust-agent`). `chump::…` in `RUST_LOG` is a common typo and is ignored.
const DEFAULT_RUST_LOG: &str = "info,\
rust_agent::agent_loop=debug,\
rust_agent::provider_cascade=debug,\
rust_agent::tool_middleware=info,\
rust_agent::task_executor=info,\
rust_agent::streaming_provider=info,\
rust_agent::local_openai=debug,\
rust_agent::discord=info,\
rust_agent::web_server=info,\
rust_agent::mistralrs_provider=info,\
warn";

/// Initialize `tracing` subscriber. Safe to call once; ignores double-init.
///
/// When compiled with `--features tokio-console`, this installs the
/// `console-subscriber` layer (connects to `tokio-console` on localhost:6669)
/// and returns early. Normal tracing setup is skipped so the console
/// subscriber owns the global default.
pub fn init() {
    #[cfg(feature = "tokio-console")]
    {
        console_subscriber::init();
        return;
    }

    #[allow(unreachable_code)]
    let filter = match EnvFilter::try_from_default_env() {
        Ok(f) => f,
        Err(_) => EnvFilter::new(DEFAULT_RUST_LOG),
    };

    let json_stderr = env_truthy("CHUMP_TRACING_JSON_STDERR");
    let file_raw = std::env::var("CHUMP_TRACING_FILE").ok();
    let file_path = file_raw.as_deref().and_then(resolve_tracing_file_path);

    let init_result = match (json_stderr, file_path) {
        (true, Some(path)) => match OpenOptions::new().create(true).append(true).open(&path) {
            Ok(file) => Registry::default()
                .with(
                    fmt::layer()
                        .json()
                        .with_target(true)
                        .with_writer(std::io::stderr)
                        .with_filter(filter.clone()),
                )
                .with(
                    fmt::layer()
                        .json()
                        .with_target(true)
                        .with_writer(Mutex::new(file))
                        .with_filter(filter),
                )
                .try_init(),
            Err(e) => {
                eprintln!(
                    "[tracing] CHUMP_TRACING_FILE open {:?} failed: {}; stderr JSON only",
                    path, e
                );
                init_json_stderr_only(filter)
            }
        },
        (true, None) => init_json_stderr_only(filter),
        (false, Some(path)) => match OpenOptions::new().create(true).append(true).open(&path) {
            Ok(file) => Registry::default()
                .with(
                    fmt::layer()
                        .with_target(true)
                        .with_writer(std::io::stderr)
                        .with_filter(filter.clone()),
                )
                .with(
                    fmt::layer()
                        .json()
                        .with_target(true)
                        .with_writer(Mutex::new(file))
                        .with_filter(filter),
                )
                .try_init(),
            Err(e) => {
                eprintln!(
                    "[tracing] CHUMP_TRACING_FILE open {:?} failed: {}; human stderr only",
                    path, e
                );
                init_human_stderr_only(filter)
            }
        },
        (false, None) => init_human_stderr_only(filter),
    };

    if let Err(_already) = init_result {
        // Subscriber already set (e.g. tests) — ignore
    }
}

fn init_json_stderr_only(filter: EnvFilter) -> Result<(), tracing_subscriber::util::TryInitError> {
    Registry::default()
        .with(
            fmt::layer()
                .json()
                .with_target(true)
                .with_writer(std::io::stderr)
                .with_filter(filter),
        )
        .try_init()
}

fn init_human_stderr_only(filter: EnvFilter) -> Result<(), tracing_subscriber::util::TryInitError> {
    Registry::default()
        .with(
            fmt::layer()
                .with_target(true)
                .with_writer(std::io::stderr)
                .with_filter(filter),
        )
        .try_init()
}
