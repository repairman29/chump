//! GitHub API rate-limit poller for `/api/stack-status` (INFRA-1337).
//!
//! Polls `gh api rate_limit` once every 60 seconds via a tokio background
//! task. `snapshot_json()` returns the most-recently-fetched snapshot or
//! `null` with a `github_rate_limit_error` string on failure.
//!
//! The poller is a fire-and-forget task started by `start_poller()` during
//! web server init. If `gh` is not installed or GitHub is unreachable, the
//! field gracefully degrades to `null`.

use std::sync::{LazyLock, RwLock};
use std::time::{Duration, Instant};

/// Cached result of one `gh api rate_limit` call.
#[derive(Clone)]
struct RateLimitCache {
    /// Pre-serialised response object ready for embedding in /api/stack-status.
    value: serde_json::Value,
    /// When this snapshot was fetched.
    fetched_at: Instant,
}

/// Global cache — `None` until first fetch completes.
static CACHE: LazyLock<RwLock<Option<RateLimitCache>>> = LazyLock::new(|| RwLock::new(None));

/// Poll interval for the background task.
const POLL_INTERVAL: Duration = Duration::from_secs(60);

/// Fetch `gh api rate_limit` synchronously (blocking). Called from the
/// background tokio task via `spawn_blocking`.
fn fetch_rate_limit_blocking() -> serde_json::Value {
    // AC4 (INFRA-2484): bypass the chump_gh shim so this telemetry-only poll
    // does not itself trigger rate-recording or exhausted-emit cycles.
    // CHUMP_GH_NO_SHIM=1   — skip the PATH shim's recording path entirely.
    // CHUMP_GH_SILENT=1    — suppress emission inside any sourced github.sh.
    let out = std::process::Command::new("gh")
        .args(["api", "rate_limit"])
        .env("CHUMP_GH_NO_SHIM", "1")
        .env("CHUMP_GH_SILENT", "1")
        .output();

    match out {
        Err(e) => {
            serde_json::json!({
                "github_rate_limit": serde_json::Value::Null,
                "github_rate_limit_error": format!("gh not found: {}", e),
            })
        }
        Ok(output) if !output.status.success() => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let snippet: String = stderr.chars().take(200).collect();
            serde_json::json!({
                "github_rate_limit": serde_json::Value::Null,
                "github_rate_limit_error": format!("gh api rate_limit failed: {}", snippet),
            })
        }
        Ok(output) => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            match serde_json::from_str::<serde_json::Value>(&stdout) {
                Err(e) => serde_json::json!({
                    "github_rate_limit": serde_json::Value::Null,
                    "github_rate_limit_error": format!("parse error: {}", e),
                }),
                Ok(raw) => {
                    // Extract the fields specified by INFRA-1337 AC#1:
                    //   graphql_remaining, graphql_limit, core_remaining,
                    //   core_limit, reset_at_iso
                    let graphql = raw.pointer("/resources/graphql");
                    let core = raw.pointer("/resources/core");

                    let graphql_remaining = graphql
                        .and_then(|g| g["remaining"].as_u64())
                        .map(serde_json::Value::from);
                    let graphql_limit = graphql
                        .and_then(|g| g["limit"].as_u64())
                        .map(serde_json::Value::from);
                    let graphql_reset = graphql
                        .and_then(|g| g["reset"].as_u64())
                        .map(|t| {
                            // Convert Unix timestamp → ISO 8601 UTC string
                            use std::time::{Duration as StdDuration, UNIX_EPOCH};
                            let dt = UNIX_EPOCH + StdDuration::from_secs(t);
                            let secs = dt
                                .duration_since(UNIX_EPOCH)
                                .map(|d| d.as_secs())
                                .unwrap_or(t);
                            // Simple RFC-3339 formatter without external deps:
                            // seconds since epoch → "YYYY-MM-DDTHH:MM:SSZ"
                            format_unix_utc(secs)
                        })
                        .map(serde_json::Value::from);

                    let core_remaining = core
                        .and_then(|c| c["remaining"].as_u64())
                        .map(serde_json::Value::from);
                    let core_limit = core
                        .and_then(|c| c["limit"].as_u64())
                        .map(serde_json::Value::from);

                    serde_json::json!({
                        "github_rate_limit": {
                            "graphql_remaining": graphql_remaining,
                            "graphql_limit": graphql_limit,
                            "core_remaining": core_remaining,
                            "core_limit": core_limit,
                            "reset_at_iso": graphql_reset,
                        }
                    })
                }
            }
        }
    }
}

/// Convert a Unix timestamp (seconds since epoch) to an ISO-8601 UTC string
/// without pulling in chrono (avoids adding a dependency for a simple formatter).
fn format_unix_utc(secs: u64) -> String {
    // Days since epoch
    let mut s = secs;
    let seconds = s % 60;
    s /= 60;
    let minutes = s % 60;
    s /= 60;
    let hours = s % 24;
    s /= 24; // s is now days since 1970-01-01

    // Gregorian calendar calculation
    let (year, month, day) = days_to_ymd(s as u32);

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hours, minutes, seconds
    )
}

fn days_to_ymd(mut d: u32) -> (u32, u32, u32) {
    // Algorithm: Civil calendar from Howard Hinnant's date library
    d += 719468;
    let era = d / 146097;
    let doe = d - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { y + 1 } else { y };
    (year, month, day)
}

/// Refresh the cache once. Called from the background task.
async fn refresh() {
    let result = tokio::task::spawn_blocking(fetch_rate_limit_blocking)
        .await
        .unwrap_or_else(|e| {
            serde_json::json!({
                "github_rate_limit": serde_json::Value::Null,
                "github_rate_limit_error": format!("spawn_blocking panic: {}", e),
            })
        });

    // Log degraded state so operators can see the gh failure in server logs.
    if result["github_rate_limit"].is_null() {
        let err = result["github_rate_limit_error"]
            .as_str()
            .unwrap_or("unknown");
        tracing::warn!(target: "chump::github_rate_limit", "fetch failed: {}", err);
    } else {
        let remaining = result
            .pointer("/github_rate_limit/graphql_remaining")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        tracing::debug!(
            target: "chump::github_rate_limit",
            graphql_remaining = remaining,
            "rate limit refreshed"
        );
    }

    let cache = RateLimitCache {
        value: result,
        fetched_at: Instant::now(),
    };

    if let Ok(mut guard) = CACHE.write() {
        *guard = Some(cache);
    }
}

/// Spawn the background polling task. Call once during server startup.
pub fn start_poller() {
    tokio::spawn(async move {
        // Fetch immediately on startup so first request has data.
        refresh().await;
        loop {
            tokio::time::sleep(POLL_INTERVAL).await;
            refresh().await;
        }
    });
}

/// Return the cached rate-limit snapshot as a JSON object suitable for
/// embedding directly in the `/api/stack-status` response.
///
/// Returns `{"github_rate_limit": null, "github_rate_limit_error": "..."}` if
/// no fetch has succeeded yet or if `gh` is unavailable.
pub fn snapshot_json() -> serde_json::Value {
    match CACHE.read() {
        Err(_) => serde_json::json!({
            "github_rate_limit": serde_json::Value::Null,
            "github_rate_limit_error": "cache lock poisoned",
        }),
        Ok(guard) => match guard.as_ref() {
            None => serde_json::json!({
                "github_rate_limit": serde_json::Value::Null,
                "github_rate_limit_error": "not yet fetched",
            }),
            Some(c) => c.value.clone(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_unix_utc_epoch() {
        assert_eq!(format_unix_utc(0), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn format_unix_utc_known_date() {
        // 2025-05-15 12:00:00 UTC → 1747310400
        assert_eq!(format_unix_utc(1747310400), "2025-05-15T12:00:00Z");
        // 2026-05-15 12:00:00 UTC → 1778846400
        assert_eq!(format_unix_utc(1778846400), "2026-05-15T12:00:00Z");
    }

    #[test]
    fn snapshot_json_before_fetch() {
        let snap = snapshot_json();
        // Before any fetch the error field must be present.
        assert!(snap.get("github_rate_limit_error").is_some());
    }
}
