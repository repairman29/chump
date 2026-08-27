//! INFRA-1645: LLM-model-call resilience for the paramedic daemon.
//!
//! The paramedic daemon occasionally needs to reach an LLM endpoint (e.g. a
//! rescue-subagent dispatch health-check). Model rollouts routinely 404 for
//! a few minutes while a deployment propagates — that's a *transient*
//! failure, not a reason to give up. This module classifies HTTP status
//! codes, retries transient failures with exponential backoff + jitter, and
//! emits structured ambient events so the fleet can see what's happening.
//!
//! Backoff shape mirrors `organ_watchdog_in_backoff` in
//! `scripts/ops/organ-watchdog.sh`: a failing unit cools down instead of
//! being hammered every cycle. Here the "cooldown" is an in-process sleep
//! between retry attempts rather than a backoff-registry file, since the
//! LLM call is synchronous and short-lived (unlike a systemd unit restart).

use anyhow::{anyhow, Result};
use serde_json::json;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// How an LLM call's HTTP status should be treated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallClass {
    /// 2xx — call succeeded.
    Success,
    /// 404 — model not yet available (rollout in progress). Retry.
    Transient404,
    /// 429 — rate limited. Retry (caller backs off the same as 404).
    RateLimited,
    /// Any other 4xx — bad request / auth / not-found-for-real. Give up.
    Permanent(u16),
}

/// Classify an HTTP status code per AC §1: 404 is transient, 429 is
/// transient (rate limit), any other 4xx is permanent.
pub fn classify_status(status: u16) -> CallClass {
    if (200..300).contains(&status) {
        CallClass::Success
    } else if status == 404 {
        CallClass::Transient404
    } else if status == 429 {
        CallClass::RateLimited
    } else {
        CallClass::Permanent(status)
    }
}

/// Exponential backoff + jitter configuration, tunable via env vars per AC §1.
#[derive(Debug, Clone, Copy)]
pub struct BackoffConfig {
    pub base_ms: u64,
    pub max_ms: u64,
    pub jitter_frac: f64,
}

impl BackoffConfig {
    pub fn from_env() -> Self {
        let base_ms = std::env::var("PARAMEDIC_BACKOFF_BASE_MS")
            .ok()
            .and_then(|v| v.parse().ok())
            .filter(|&n: &u64| n > 0)
            .unwrap_or(500);
        let max_ms = std::env::var("PARAMEDIC_BACKOFF_MAX_MS")
            .ok()
            .and_then(|v| v.parse().ok())
            .filter(|&n: &u64| n > 0)
            .unwrap_or(30_000);
        let jitter_frac = std::env::var("PARAMEDIC_BACKOFF_JITTER")
            .ok()
            .and_then(|v| v.parse().ok())
            .filter(|&f: &f64| (0.0..=1.0).contains(&f))
            .unwrap_or(0.2);
        Self {
            base_ms,
            max_ms,
            jitter_frac,
        }
    }

    /// Backoff delay for the given (0-indexed) retry attempt: doubling from
    /// `base_ms`, capped at `max_ms`, with +/- `jitter_frac` jitter applied.
    pub fn delay_ms(&self, attempt: u32) -> u64 {
        let exp = self.base_ms.saturating_mul(1u64 << attempt.min(20));
        let capped = exp.min(self.max_ms);
        if self.jitter_frac <= 0.0 || capped == 0 {
            return capped;
        }
        let jitter_span = ((capped as f64) * self.jitter_frac) as u64;
        if jitter_span == 0 {
            return capped;
        }
        let r = pseudo_random(jitter_span * 2 + 1);
        // Center the jitter: [-jitter_span, +jitter_span].
        let offset = r as i64 - jitter_span as i64;
        (capped as i64 + offset).max(0) as u64
    }
}

/// Cheap non-cryptographic jitter source (no `rand` dependency needed for a
/// retry-delay wobble). Seeded from the wall clock so consecutive calls
/// don't produce identical jitter.
fn pseudo_random(modulus: u64) -> u64 {
    if modulus == 0 {
        return 0;
    }
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as u64)
        .unwrap_or(0);
    let mixed = nanos
        .wrapping_mul(6364136223846793005)
        .wrapping_add(1442695040888963407);
    mixed % modulus
}

/// Outcome of a resilient LLM call.
#[derive(Debug)]
pub struct CallOutcome {
    pub status: u16,
    pub attempts: u32,
}

/// Minimal HTTP GET over a raw TCP stream — just enough to read a status
/// line back from a mock/real LLM endpoint. Avoids pulling in a full HTTP
/// client dependency for what is a single-shot health-check call.
pub fn http_get_status(url: &str) -> Result<u16> {
    let rest = url
        .strip_prefix("http://")
        .ok_or_else(|| anyhow!("only http:// URLs are supported: {url}"))?;
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let mut stream = TcpStream::connect(authority)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let host = authority.split(':').next().unwrap_or(authority);
    let req = format!("GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n");
    stream.write_all(req.as_bytes())?;

    let mut buf = Vec::new();
    stream.read_to_end(&mut buf)?;
    let text = String::from_utf8_lossy(&buf);
    let status_line = text
        .lines()
        .next()
        .ok_or_else(|| anyhow!("empty response from {url}"))?;
    // "HTTP/1.1 200 OK"
    let status = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse::<u16>().ok())
        .ok_or_else(|| anyhow!("malformed status line: {status_line}"))?;
    Ok(status)
}

/// Call `url`, retrying `Transient404`/`RateLimited` responses with
/// exponential backoff + jitter, up to `max_attempts`. Emits
/// `model_unavailable` on each 404 retry, `paramedic_healthy` on success,
/// and `permanent_failure` (then returns Err) on any other 4xx.
pub fn call_llm_with_resilience(
    repo_root: &Path,
    url: &str,
    max_attempts: u32,
) -> Result<CallOutcome> {
    let cfg = BackoffConfig::from_env();
    let mut attempt: u32 = 0;

    loop {
        attempt += 1;
        let status_result = http_get_status(url);

        let status = match status_result {
            Ok(s) => s,
            Err(e) => {
                if attempt >= max_attempts {
                    emit_event(
                        repo_root,
                        "permanent_failure",
                        json!({"url": url, "attempts": attempt, "reason": e.to_string()}),
                    );
                    return Err(anyhow!("llm call failed after {attempt} attempts: {e}"));
                }
                std::thread::sleep(Duration::from_millis(cfg.delay_ms(attempt - 1)));
                continue;
            }
        };

        match classify_status(status) {
            CallClass::Success => {
                emit_event(
                    repo_root,
                    "paramedic_healthy",
                    json!({"url": url, "status": status, "attempts": attempt}),
                );
                return Ok(CallOutcome {
                    status,
                    attempts: attempt,
                });
            }
            CallClass::Transient404 | CallClass::RateLimited => {
                emit_event(
                    repo_root,
                    "model_unavailable",
                    json!({"url": url, "status": status, "attempt": attempt}),
                );
                if attempt >= max_attempts {
                    emit_event(
                        repo_root,
                        "permanent_failure",
                        json!({"url": url, "status": status, "attempts": attempt, "reason": "max_attempts_exhausted"}),
                    );
                    return Err(anyhow!(
                        "llm call still returning {status} after {attempt} attempts"
                    ));
                }
                std::thread::sleep(Duration::from_millis(cfg.delay_ms(attempt - 1)));
            }
            CallClass::Permanent(code) => {
                emit_event(
                    repo_root,
                    "permanent_failure",
                    json!({"url": url, "status": code, "attempts": attempt}),
                );
                return Err(anyhow!("llm call returned permanent failure status {code}"));
            }
        }
    }
}

/// Append a structured event to `.chump-locks/ambient.jsonl`.
pub fn emit_event(repo_root: &Path, kind: &str, mut fields: serde_json::Value) {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Some(obj) = fields.as_object_mut() {
        obj.insert("ts".to_string(), json!(iso8601_now()));
        obj.insert("kind".to_string(), json!(kind));
    }
    let line = serde_json::to_string(&fields).unwrap_or_default() + "\n";
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn iso8601_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// A dummy in-process "LLM call" used by `--smoke-test`: no network I/O, just
/// deterministic token/cost numbers so the smoke test is fast and offline-safe.
pub fn dummy_llm_call() -> (u64, f64) {
    let tokens_used: u64 = 128;
    let estimated_cost_usd: f64 = tokens_used as f64 * 0.000_003;
    (tokens_used, estimated_cost_usd)
}

/// `--smoke-test`: a quick observability check. Performs a dummy LLM call,
/// emits `kind=cost_report` to ambient, and prints the same event as a JSON
/// line to stdout so a human/CI can eyeball it without tailing ambient.jsonl.
pub fn smoke_test(repo_root: &Path) -> Result<()> {
    let (tokens_used, estimated_cost_usd) = dummy_llm_call();
    let event = json!({
        "ts": iso8601_now(),
        "event": "cost_report",
        "kind": "cost_report",
        "tokens_used": tokens_used,
        "estimated_cost_usd": estimated_cost_usd,
    });
    emit_event(
        repo_root,
        "cost_report",
        json!({"tokens_used": tokens_used, "estimated_cost_usd": estimated_cost_usd}),
    );
    println!("{}", serde_json::to_string(&event)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_status_matches_ac() {
        assert_eq!(classify_status(200), CallClass::Success);
        assert_eq!(classify_status(404), CallClass::Transient404);
        assert_eq!(classify_status(429), CallClass::RateLimited);
        assert_eq!(classify_status(403), CallClass::Permanent(403));
        assert_eq!(classify_status(500), CallClass::Permanent(500));
    }

    #[test]
    fn backoff_doubles_and_caps() {
        let cfg = BackoffConfig {
            base_ms: 100,
            max_ms: 1000,
            jitter_frac: 0.0,
        };
        assert_eq!(cfg.delay_ms(0), 100);
        assert_eq!(cfg.delay_ms(1), 200);
        assert_eq!(cfg.delay_ms(2), 400);
        assert_eq!(cfg.delay_ms(10), 1000); // capped
    }
}
