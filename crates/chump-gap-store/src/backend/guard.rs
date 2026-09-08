//! Split-brain guard — RESILIENT-1057.
//!
//! `.chump/state.db` (SQLite, via [`crate::GapStore`]) is the **canonical**
//! gap store. The PostgREST/Postgres surface (`shared_gaps`, reachable via
//! `CHUMP_GAP_STORE_URL` — see `scripts/setup/install-gap-substrate.sh`) is
//! an optional, **dormant** second surface (INFRA-2092). It must never be
//! allowed to silently diverge from SQLite and be trusted as if it were
//! also canonical.
//!
//! Before this guard existed, the second store could be completely broken
//! (e.g. `42501 permission denied to set role chump_anon`, empty behind a
//! stale process on an old conf) and nothing would notice — the fleet just
//! happened to work because every real caller reads SQLite. That's a latent
//! split-brain: the moment something *does* start reading the second store
//! (a new integration, a misconfigured client, a future migration attempt)
//! it would silently disagree with SQLite instead of failing loudly.
//!
//! This module holds the pure decision logic so it can be unit-tested
//! without a live network dependency. Callers (`chump-gap-doctor
//! check-second-store`) are responsible for probing the real endpoint and
//! feeding the result in via [`SecondStoreState`].

/// What we observed when probing the second store (or didn't probe at all).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecondStoreState {
    /// `CHUMP_GAP_STORE_URL` is unset — SQLite-only. This is the expected
    /// default and the healthiest state: there is no second store to
    /// diverge from.
    NotConfigured,
    /// Configured, but the probe failed (connection refused, DNS failure,
    /// non-2xx HTTP status, permission-denied role error, etc). Treated as
    /// dormant, not alarming — a broken-but-declared-dormant second store
    /// can't cause split-brain because nothing can read consistent data
    /// from it either.
    Unreachable { detail: String },
    /// Configured and responded with an open-gap count. This is the only
    /// state that can actually diverge from SQLite, because it's the only
    /// state where the second store is serving live data.
    Reachable { open_count: u64 },
}

/// The guard's verdict, given SQLite's open-gap count and the second
/// store's observed state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitBrainVerdict {
    /// No second store configured — SQLite is trivially canonical.
    Canonical,
    /// Second store configured but unreachable — dormant as declared, no
    /// divergence is possible.
    DormantOk,
    /// Second store configured, reachable, and its open-gap count agrees
    /// with SQLite's.
    Consistent,
    /// Second store configured, reachable, and its open-gap count
    /// *disagrees* with SQLite's — the exact silent-split-brain condition
    /// this gap exists to catch.
    Diverged { sqlite_open: u64, remote_open: u64 },
}

impl SplitBrainVerdict {
    /// True for the one verdict that should fail a CI/doctor gate.
    pub fn is_alarm(&self) -> bool {
        matches!(self, SplitBrainVerdict::Diverged { .. })
    }

    pub fn render(&self) -> String {
        match self {
            SplitBrainVerdict::Canonical => {
                "sqlite canonical (no second store configured)".to_string()
            }
            SplitBrainVerdict::DormantOk => {
                "second store configured but unreachable — dormant as declared".to_string()
            }
            SplitBrainVerdict::Consistent => {
                "second store reachable and consistent with sqlite".to_string()
            }
            SplitBrainVerdict::Diverged {
                sqlite_open,
                remote_open,
            } => format!(
                "SPLIT-BRAIN: sqlite open={sqlite_open} vs second-store open={remote_open} — \
                 second store is live and disagrees with the canonical store"
            ),
        }
    }
}

/// Evaluate whether the second store (if any) has drifted from SQLite's
/// open-gap count.
pub fn evaluate(sqlite_open: u64, second_store: &SecondStoreState) -> SplitBrainVerdict {
    match second_store {
        SecondStoreState::NotConfigured => SplitBrainVerdict::Canonical,
        SecondStoreState::Unreachable { .. } => SplitBrainVerdict::DormantOk,
        SecondStoreState::Reachable { open_count } => {
            if *open_count == sqlite_open {
                SplitBrainVerdict::Consistent
            } else {
                SplitBrainVerdict::Diverged {
                    sqlite_open,
                    remote_open: *open_count,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn not_configured_is_canonical_and_not_an_alarm() {
        let verdict = evaluate(1946, &SecondStoreState::NotConfigured);
        assert_eq!(verdict, SplitBrainVerdict::Canonical);
        assert!(!verdict.is_alarm());
    }

    #[test]
    fn unreachable_is_dormant_ok_and_not_an_alarm() {
        let verdict = evaluate(
            1946,
            &SecondStoreState::Unreachable {
                detail: "42501 permission denied to set role chump_anon".to_string(),
            },
        );
        assert_eq!(verdict, SplitBrainVerdict::DormantOk);
        assert!(!verdict.is_alarm());
    }

    #[test]
    fn reachable_and_matching_counts_is_consistent() {
        let verdict = evaluate(1946, &SecondStoreState::Reachable { open_count: 1946 });
        assert_eq!(verdict, SplitBrainVerdict::Consistent);
        assert!(!verdict.is_alarm());
    }

    /// The load-bearing regression: a second store that is reachable but
    /// disagrees with sqlite's open-gap count MUST be flagged as an alarm.
    /// Without the guard (i.e. before this change), this exact condition
    /// was invisible — the fleet just silently ran on sqlite.
    #[test]
    fn reachable_and_diverging_counts_is_an_alarm() {
        let verdict = evaluate(1946, &SecondStoreState::Reachable { open_count: 0 });
        assert_eq!(
            verdict,
            SplitBrainVerdict::Diverged {
                sqlite_open: 1946,
                remote_open: 0
            }
        );
        assert!(verdict.is_alarm());
    }

    #[test]
    fn render_mentions_split_brain_on_divergence() {
        let verdict = evaluate(10, &SecondStoreState::Reachable { open_count: 3 });
        assert!(verdict.render().contains("SPLIT-BRAIN"));
    }
}
