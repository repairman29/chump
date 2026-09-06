//! EFFECTIVE-1351 (EFFECTIVE-178 slice): `chump wait <condition>` and
//! `chump pr wait <N> --until merged` — block the calling shell until a
//! condition source flips true or a PR merges, instead of the caller
//! hand-rolling a polling loop with `sleep 5 && gh pr view ...`.
//!
//! Both commands share the same poll engine ([`poll_until`]) so the
//! blocking/timeout behavior is tested once and reused. Condition/PR-state
//! lookups are pluggable ([`ConditionChecker`] / `PrStateFn`) so tests never
//! shell out or sleep for real.

use anyhow::{anyhow, Result};
use std::time::Duration;

pub const DEFAULT_POLL_INTERVAL_SECS: u64 = 5;
pub const DEFAULT_TIMEOUT_SECS: u64 = 300;

/// Returns true once the named condition is satisfied.
pub type ConditionChecker<'a> = Box<dyn FnMut(&str) -> bool + 'a>;

/// Returns the current PR state (`"OPEN"` | `"MERGED"` | `"CLOSED"`), or
/// `None` on lookup failure (treated as "not yet satisfied").
pub type PrStateChecker<'a> = Box<dyn FnMut(u64) -> Option<String> + 'a>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WaitResult {
    Satisfied { elapsed_secs: u64, polls: u32 },
    TimedOut { elapsed_secs: u64, polls: u32 },
}

impl WaitResult {
    pub fn is_success(&self) -> bool {
        matches!(self, WaitResult::Satisfied { .. })
    }
}

/// Generic poll loop: calls `check` immediately, then every `interval_secs`
/// until `check` returns true or `timeout_secs` elapses. `sleep_fn` is
/// injected so tests can fast-forward without real time passing.
pub fn poll_until(
    mut check: impl FnMut() -> bool,
    timeout_secs: u64,
    interval_secs: u64,
    mut sleep_fn: impl FnMut(u64),
) -> WaitResult {
    let mut elapsed = 0u64;
    let mut polls = 0u32;
    loop {
        polls += 1;
        if check() {
            return WaitResult::Satisfied {
                elapsed_secs: elapsed,
                polls,
            };
        }
        if elapsed >= timeout_secs {
            return WaitResult::TimedOut {
                elapsed_secs: elapsed,
                polls,
            };
        }
        sleep_fn(interval_secs);
        elapsed += interval_secs;
    }
}

/// `chump wait <condition> [--timeout <secs>]` — blocks until `checker`
/// reports the condition true.
pub fn wait_for_condition(
    condition: &str,
    timeout_secs: u64,
    interval_secs: u64,
    mut checker: ConditionChecker<'_>,
    sleep_fn: impl FnMut(u64),
) -> WaitResult {
    poll_until(|| checker(condition), timeout_secs, interval_secs, sleep_fn)
}

/// `chump pr wait <N> --until merged [--timeout <secs>]` — blocks until
/// `checker(pr_number)` reports `"MERGED"`.
pub fn wait_for_pr_merged(
    pr_number: u64,
    timeout_secs: u64,
    interval_secs: u64,
    mut checker: PrStateChecker<'_>,
    sleep_fn: impl FnMut(u64),
) -> WaitResult {
    poll_until(
        || {
            checker(pr_number)
                .map(|s| s.eq_ignore_ascii_case("MERGED"))
                .unwrap_or(false)
        },
        timeout_secs,
        interval_secs,
        sleep_fn,
    )
}

/// Default condition checker. Supports:
///   - `fleet:healthy`   → exit-0 of `scripts/coord/fleet-doctor-strict.sh`
///   - `shell:<command>` → exit-0 of `sh -c <command>`
///
/// Unknown namespaces always report unsatisfied (never silently "pass").
pub fn default_condition_checker() -> ConditionChecker<'static> {
    Box::new(|condition: &str| -> bool {
        if condition == "fleet:healthy" {
            return std::process::Command::new("scripts/coord/fleet-doctor-strict.sh")
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
        }
        if let Some(cmd) = condition.strip_prefix("shell:") {
            return std::process::Command::new("sh")
                .args(["-c", cmd])
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
        }
        false
    })
}

/// Default PR-state checker — shells out to `gh pr view <N> --json state`.
pub fn default_pr_state_checker() -> PrStateChecker<'static> {
    Box::new(|pr_number: u64| -> Option<String> {
        let out = std::process::Command::new("gh")
            .args(["pr", "view", &pr_number.to_string(), "--json", "state"])
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let v: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
        v.get("state").and_then(|s| s.as_str()).map(String::from)
    })
}

fn real_sleep(secs: u64) {
    std::thread::sleep(Duration::from_secs(secs));
}

/// `chump wait <condition> [--timeout <secs>]` entry point.
pub fn run_wait(condition: &str, timeout_secs: u64) -> Result<()> {
    if condition.is_empty() {
        return Err(anyhow!("Usage: chump wait <condition> [--timeout <secs>]"));
    }
    let result = wait_for_condition(
        condition,
        timeout_secs,
        DEFAULT_POLL_INTERVAL_SECS,
        default_condition_checker(),
        real_sleep,
    );
    report_and_exit(condition, &result)
}

/// `chump pr wait <N> --until merged [--timeout <secs>]` entry point.
pub fn run_pr_wait(pr_number: u64, until: &str, timeout_secs: u64) -> Result<()> {
    if until != "merged" {
        return Err(anyhow!(
            "chump pr wait: unsupported --until value '{until}' (only 'merged' is supported)"
        ));
    }
    let result = wait_for_pr_merged(
        pr_number,
        timeout_secs,
        DEFAULT_POLL_INTERVAL_SECS,
        default_pr_state_checker(),
        real_sleep,
    );
    report_and_exit(&format!("PR #{pr_number} merged"), &result)
}

fn report_and_exit(label: &str, result: &WaitResult) -> Result<()> {
    match result {
        WaitResult::Satisfied {
            elapsed_secs,
            polls,
        } => {
            println!("chump wait: '{label}' satisfied after {elapsed_secs}s ({polls} polls)");
            Ok(())
        }
        WaitResult::TimedOut {
            elapsed_secs,
            polls,
        } => Err(anyhow!(
            "chump wait: '{label}' timed out after {elapsed_secs}s ({polls} polls)"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn condition_true_on_first_poll_returns_immediately() {
        let checker: ConditionChecker = Box::new(|_c: &str| true);
        let result = wait_for_condition("fleet:healthy", 30, 5, checker, |_| {});
        assert_eq!(
            result,
            WaitResult::Satisfied {
                elapsed_secs: 0,
                polls: 1
            }
        );
        assert!(result.is_success());
    }

    #[test]
    fn condition_becomes_true_after_n_polls() {
        let calls = RefCell::new(0u32);
        let checker: ConditionChecker = Box::new(|_c: &str| {
            let mut n = calls.borrow_mut();
            *n += 1;
            *n >= 3
        });
        let sleeps = RefCell::new(0u32);
        let result = wait_for_condition("fleet:healthy", 30, 5, checker, |_| {
            *sleeps.borrow_mut() += 1;
        });
        assert_eq!(
            result,
            WaitResult::Satisfied {
                elapsed_secs: 10,
                polls: 3
            }
        );
        assert_eq!(*sleeps.borrow(), 2);
    }

    #[test]
    fn condition_never_true_times_out() {
        let checker: ConditionChecker = Box::new(|_c: &str| false);
        let result = wait_for_condition("fleet:healthy", 10, 5, checker, |_| {});
        assert!(!result.is_success());
        match result {
            WaitResult::TimedOut { elapsed_secs, .. } => assert_eq!(elapsed_secs, 10),
            _ => panic!("expected TimedOut"),
        }
    }

    #[test]
    fn pr_wait_satisfied_when_state_merged() {
        let checker: PrStateChecker = Box::new(|_n: u64| Some("MERGED".to_string()));
        let result = wait_for_pr_merged(42, 30, 5, checker, |_| {});
        assert!(result.is_success());
    }

    #[test]
    fn pr_wait_open_then_merged() {
        let calls = RefCell::new(0u32);
        let checker: PrStateChecker = Box::new(|_n: u64| {
            let mut c = calls.borrow_mut();
            *c += 1;
            if *c < 2 {
                Some("OPEN".to_string())
            } else {
                Some("MERGED".to_string())
            }
        });
        let result = wait_for_pr_merged(42, 30, 5, checker, |_| {});
        assert_eq!(
            result,
            WaitResult::Satisfied {
                elapsed_secs: 5,
                polls: 2
            }
        );
    }

    #[test]
    fn pr_wait_closed_without_merge_times_out() {
        let checker: PrStateChecker = Box::new(|_n: u64| Some("CLOSED".to_string()));
        let result = wait_for_pr_merged(42, 10, 5, checker, |_| {});
        assert!(!result.is_success());
    }

    #[test]
    fn pr_wait_lookup_failure_treated_as_unsatisfied() {
        let checker: PrStateChecker = Box::new(|_n: u64| None);
        let result = wait_for_pr_merged(42, 5, 5, checker, |_| {});
        assert!(!result.is_success());
    }

    #[test]
    fn run_pr_wait_rejects_unsupported_until_value() {
        let err = run_pr_wait(1, "closed", 5).unwrap_err();
        assert!(err.to_string().contains("unsupported --until"));
    }

    #[test]
    fn run_wait_rejects_empty_condition() {
        let err = run_wait("", 5).unwrap_err();
        assert!(err.to_string().contains("Usage"));
    }

    #[test]
    fn default_condition_checker_unknown_namespace_is_false() {
        let mut checker = default_condition_checker();
        assert!(!checker("nonsense:whatever"));
    }
}
