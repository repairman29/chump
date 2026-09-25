//! Central token-bucket rate limiter for GitHub API calls across the fleet (INFRA-4246).
//!
//! Complements the shell sliding-window self-throttle in
//! `scripts/coord/lib/github.sh` (INFRA-1079/1112) with a single shared,
//! file-backed bucket any process (Rust or shell, via the `chump ratelimit
//! check-gh` CLI) can consult for an allow/deny decision instead of a
//! blocking wait. State lives at `.chump-locks/gh-token-bucket.json` by
//! default so the whole fleet reads/writes the same bucket.

use serde::{Deserialize, Serialize};
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Refill window: `capacity` tokens are available per this many milliseconds.
const WINDOW_MS: u64 = 60_000;

/// Result of a single `check` call.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Decision {
    pub allow: bool,
    /// Milliseconds to wait before the next token becomes available.
    /// Always `0` when `allow` is `true`.
    pub retry_after_ms: u64,
}

#[derive(Serialize, Deserialize)]
struct BucketState {
    tokens: f64,
    last_refill_ms: u64,
}

/// Default bucket capacity: `CHUMP_GH_MAX_CALLS_PER_MIN` (AC1), falling back
/// to 60/min — the same default the shell throttle uses.
pub fn default_capacity() -> u32 {
    std::env::var("CHUMP_GH_MAX_CALLS_PER_MIN")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60)
}

/// Default shared-state path, overridable for tests / alternate roots.
pub fn default_state_path(repo_root: &Path) -> PathBuf {
    std::env::var("CHUMP_GH_TOKEN_BUCKET_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root.join(".chump-locks/gh-token-bucket.json"))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// Consult the shared bucket at `state_path` (capacity `capacity` tokens per
/// `WINDOW_MS`) at time `now_ms`, consuming a token on allow. Deterministic
/// given `now_ms` — used directly by tests; `check_now` wraps it with the
/// real clock for callers.
pub fn check(state_path: &Path, capacity: u32, now_ms: u64) -> io::Result<Decision> {
    if capacity == 0 {
        // Disabled — mirrors CHUMP_GH_NO_THROTTLE / limit<=0 in the shell throttle.
        return Ok(Decision {
            allow: true,
            retry_after_ms: 0,
        });
    }

    if let Some(parent) = state_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let mut state = read_state(state_path).unwrap_or(BucketState {
        tokens: capacity as f64,
        last_refill_ms: now_ms,
    });

    let refill_rate = capacity as f64 / WINDOW_MS as f64; // tokens per ms
    let elapsed = now_ms.saturating_sub(state.last_refill_ms) as f64;
    state.tokens = (state.tokens + elapsed * refill_rate).min(capacity as f64);
    state.last_refill_ms = now_ms;

    let decision = if state.tokens >= 1.0 {
        state.tokens -= 1.0;
        Decision {
            allow: true,
            retry_after_ms: 0,
        }
    } else {
        let deficit = 1.0 - state.tokens;
        let retry_after_ms = (deficit / refill_rate).ceil() as u64;
        Decision {
            allow: false,
            retry_after_ms,
        }
    };

    write_state(state_path, &state)?;
    Ok(decision)
}

/// `check` using the real wall clock — the entry point for production callers.
pub fn check_now(state_path: &Path, capacity: u32) -> io::Result<Decision> {
    check(state_path, capacity, now_ms())
}

fn read_state(path: &Path) -> Option<BucketState> {
    let data = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&data).ok()
}

fn write_state(path: &Path, state: &BucketState) -> io::Result<()> {
    let data = serde_json::to_string(state)?;
    // Write-then-rename keeps concurrent readers from observing a partial file;
    // matches the atomic-swap pattern used by the shell throttle's window file.
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_state_path(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chump-gh-token-bucket-test-{}-{}",
            name,
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("bucket.json")
    }

    #[test]
    fn allows_up_to_capacity_then_denies() {
        let path = tmp_state_path("allows_up_to_capacity");
        let capacity = 3;
        let now = 0;

        for _ in 0..capacity {
            let d = check(&path, capacity, now).unwrap();
            assert!(d.allow, "expected allow within capacity");
            assert_eq!(d.retry_after_ms, 0);
        }

        let d = check(&path, capacity, now).unwrap();
        assert!(!d.allow, "expected deny once capacity exhausted");
        assert!(d.retry_after_ms > 0, "deny must report retry_after_ms");
    }

    #[test]
    fn refills_over_time() {
        let path = tmp_state_path("refills_over_time");
        let capacity = 60; // 1 token/sec at WINDOW_MS=60_000
        let mut now = 0u64;

        // Drain the bucket.
        for _ in 0..capacity {
            assert!(check(&path, capacity, now).unwrap().allow);
        }
        let denied = check(&path, capacity, now).unwrap();
        assert!(!denied.allow);

        // Advance past the reported retry_after_ms — must now allow.
        now += denied.retry_after_ms;
        let d = check(&path, capacity, now).unwrap();
        assert!(d.allow, "expected allow after waiting retry_after_ms");
    }

    #[test]
    fn zero_capacity_disables_limiter() {
        let path = tmp_state_path("zero_capacity");
        for _ in 0..5 {
            let d = check(&path, 0, 0).unwrap();
            assert!(d.allow);
            assert_eq!(d.retry_after_ms, 0);
        }
    }

    #[test]
    fn state_persists_across_calls_to_same_path() {
        let path = tmp_state_path("persists");
        let capacity = 2;
        assert!(check(&path, capacity, 0).unwrap().allow);
        assert!(check(&path, capacity, 0).unwrap().allow);
        // Third call at the same instant (no refill) must deny — proves the
        // state file round-trips tokens across separate `check` invocations,
        // i.e. is shared across processes rather than per-call in-memory.
        assert!(!check(&path, capacity, 0).unwrap().allow);
    }
}
