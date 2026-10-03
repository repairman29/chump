//! INFRA-4246 (INFRA-1319 slice): central token-bucket rate limiter.
//!
//! A single file-backed token bucket shared by every process in the fleet
//! (readers/writers from every worktree resolve to the same
//! `.chump-locks/rate-bucket.json` via `repo_path::main_checkout_root()`),
//! so `CHUMP_GH_MAX_CALLS_PER_MIN` is respected across the whole fleet, not
//! per-process.
//!
//! The bucket refills continuously at `limit / 60` tokens per second, caps
//! at `limit` tokens, and `try_acquire()` either consumes one token (Allow)
//! or reports how long to wait before the next token is available
//! (Deny { retry_after_ms }). File access is serialized with `flock` so
//! concurrent callers across processes get a consistent decision.

use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Decision returned by `try_acquire()`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "lowercase")]
pub enum Decision {
    Allow,
    Deny { retry_after_ms: u64 },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BucketState {
    /// Tokens available, fixed-point-free (fractional tokens allowed).
    tokens: f64,
    /// Unix epoch millis of the last refill computation.
    last_refill_ms: u64,
}

/// Returns the path to the fleet-wide shared bucket state file.
pub fn bucket_state_path() -> PathBuf {
    crate::repo_path::main_checkout_root()
        .join(".chump-locks")
        .join("rate-bucket.json")
}

/// Reads `CHUMP_GH_MAX_CALLS_PER_MIN` (default 60), clamped to >= 1.
pub fn configured_limit_per_min() -> u64 {
    std::env::var("CHUMP_GH_MAX_CALLS_PER_MIN")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(60)
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Attempt to consume one token from the fleet-wide bucket at `state_path`,
/// with capacity/refill-rate derived from `limit_per_min`.
///
/// Locking: opens (creating if absent) `state_path`, takes an exclusive
/// `flock`, reads-modifies-writes the JSON state, then releases the lock on
/// drop. This is the same serialization strategy the bash self-throttle
/// (`scripts/coord/lib/github.sh`) uses for its sliding-window file.
pub fn try_acquire_at(state_path: &Path, limit_per_min: u64) -> std::io::Result<Decision> {
    if let Some(parent) = state_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // `truncate(false)` is explicit: the file is read first to recover the
    // existing bucket state, then rewritten in place via `set_len`/`seek`
    // below after the new state is computed.
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(state_path)?;

    lock_exclusive(&file)?;

    let mut contents = String::new();
    file.read_to_string(&mut contents)?;

    let now = now_ms();
    let capacity = limit_per_min as f64;
    let refill_per_ms = capacity / 60_000.0;

    let mut state = serde_json::from_str::<BucketState>(&contents).unwrap_or(BucketState {
        tokens: capacity,
        last_refill_ms: now,
    });

    let elapsed_ms = now.saturating_sub(state.last_refill_ms) as f64;
    state.tokens = (state.tokens + elapsed_ms * refill_per_ms).min(capacity);
    state.last_refill_ms = now;

    let decision = if state.tokens >= 1.0 {
        state.tokens -= 1.0;
        Decision::Allow
    } else {
        let tokens_needed = 1.0 - state.tokens;
        let retry_after_ms = if refill_per_ms > 0.0 {
            (tokens_needed / refill_per_ms).ceil() as u64
        } else {
            60_000
        };
        Decision::Deny { retry_after_ms }
    };

    let serialized = serde_json::to_string(&state).map_err(std::io::Error::other)?;
    file.set_len(0)?;
    file.seek(SeekFrom::Start(0))?;
    file.write_all(serialized.as_bytes())?;
    file.flush()?;

    // Lock released on drop of `file`.
    Ok(decision)
}

/// Convenience wrapper: fleet-wide path + `CHUMP_GH_MAX_CALLS_PER_MIN`.
pub fn try_acquire() -> std::io::Result<Decision> {
    try_acquire_at(&bucket_state_path(), configured_limit_per_min())
}

#[cfg(unix)]
fn lock_exclusive(file: &File) -> std::io::Result<()> {
    use std::os::unix::io::AsRawFd;
    let fd = file.as_raw_fd();
    // SAFETY: fd is a valid, open file descriptor owned by `file` for the
    // duration of this call; flock blocks until the lock is acquired.
    let rc = unsafe { libc::flock(fd, libc::LOCK_EX) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(unix))]
fn lock_exclusive(_file: &File) -> std::io::Result<()> {
    Ok(())
}

/// CLI entry point: `chump rate-limit check [--json]`.
///
/// Exits 0 (Allow) or 1 (Deny). On `--json`, prints the `Decision` as JSON
/// to stdout regardless of outcome.
pub fn run_cli(args: &[String]) -> i32 {
    let want_json = args.iter().any(|a| a == "--json");

    match try_acquire() {
        Ok(decision) => {
            if want_json {
                println!(
                    "{}",
                    serde_json::to_string(&decision).unwrap_or_else(|_| "{}".to_string())
                );
            } else {
                match &decision {
                    Decision::Allow => println!("allow"),
                    Decision::Deny { retry_after_ms } => {
                        println!("deny retry_after_ms={}", retry_after_ms)
                    }
                }
            }
            match decision {
                Decision::Allow => 0,
                Decision::Deny { .. } => 1,
            }
        }
        Err(e) => {
            eprintln!("chump rate-limit check: error: {}", e);
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_state_path(name: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-rate-bucket-test-{}-{}",
            std::process::id(),
            name
        ));
        p
    }

    #[test]
    fn allows_within_limit() {
        let path = temp_state_path("allows_within_limit");
        let _ = std::fs::remove_file(&path);

        // Capacity 5/min: first 5 acquisitions should all be allowed.
        for _ in 0..5 {
            let decision = try_acquire_at(&path, 5).expect("acquire ok");
            assert_eq!(decision, Decision::Allow);
        }

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn denies_once_exhausted_with_retry_after() {
        let path = temp_state_path("denies_once_exhausted");
        let _ = std::fs::remove_file(&path);

        for _ in 0..3 {
            assert_eq!(try_acquire_at(&path, 3).unwrap(), Decision::Allow);
        }

        match try_acquire_at(&path, 3).unwrap() {
            Decision::Deny { retry_after_ms } => assert!(retry_after_ms > 0),
            Decision::Allow => panic!("expected deny after exhausting bucket"),
        }

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn refills_over_time() {
        let path = temp_state_path("refills_over_time");
        let _ = std::fs::remove_file(&path);

        // Capacity 60/min = 1 token/sec refill. Drain to empty, back-date
        // last_refill_ms to simulate elapsed time, then expect an Allow.
        for _ in 0..60 {
            let _ = try_acquire_at(&path, 60).unwrap();
        }
        match try_acquire_at(&path, 60).unwrap() {
            Decision::Deny { .. } => {}
            Decision::Allow => panic!("expected deny after draining bucket"),
        }

        // Manually rewind last_refill_ms by 2000ms to simulate elapsed time.
        let mut contents = std::fs::read_to_string(&path).unwrap();
        let mut state: BucketState = serde_json::from_str(&contents).unwrap();
        state.last_refill_ms = state.last_refill_ms.saturating_sub(2000);
        contents = serde_json::to_string(&state).unwrap();
        std::fs::write(&path, contents).unwrap();

        let decision = try_acquire_at(&path, 60).unwrap();
        assert_eq!(decision, Decision::Allow);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn default_limit_is_sixty_when_unset() {
        std::env::remove_var("CHUMP_GH_MAX_CALLS_PER_MIN");
        assert_eq!(configured_limit_per_min(), 60);
    }

    #[test]
    fn respects_env_override() {
        std::env::set_var("CHUMP_GH_MAX_CALLS_PER_MIN", "12");
        assert_eq!(configured_limit_per_min(), 12);
        std::env::remove_var("CHUMP_GH_MAX_CALLS_PER_MIN");
    }
}
