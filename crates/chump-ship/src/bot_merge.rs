//! `BotMergePath` — STUBBED in Phase 1 (INFRA-2001).
//!
//! Phase 2 sub-gap will port the body of `scripts/coord/bot-merge.sh`
//! (3044 LOC of bash) into Rust. Phase 1 ships:
//!
//! - The [`BotMergePath`] type itself (so consumers can wire `ShipMode::BotMerge`).
//! - A `ship()` impl that returns [`ShipError::BotMergeDoubleInstance`]
//!   with a "not yet implemented" diagnostic.
//! - The `preflight()` impl mirrors [`crate::manual_ship::ManualShipPath`]
//!   for diagnostic surface — but `ship()` itself refuses.
//!
//! Why ship the stub now: callers (the CLI, the bash shim, future
//! integrations) can be written against the trait surface today
//! without each branch needing to be feature-gated. Phase 2 lights
//! it up internally.

use std::path::{Path, PathBuf};

use async_trait::async_trait;

use crate::ship::{PreflightReport, Ship, ShipError, ShipIntent, ShipReceipt};

/// Autonomous bot-merge ship executor — STUBBED in Phase 1.
///
/// Construct via [`BotMergePath::new`]. `ship()` always errors with
/// [`ShipError::BotMergeDoubleInstance`] carrying a "Phase 1 not
/// implemented" diagnostic so consumers can detect the stub at
/// runtime + fall back to the bash callsite.
pub struct BotMergePath {
    intent: ShipIntent<'static>,
    /// Repo root — held for future use when Phase 2 lights this up.
    /// Marked `#[allow(dead_code)]` because Phase 1 doesn't reference it
    /// from `ship()` (the impl returns early).
    #[allow(dead_code)]
    repo_root: PathBuf,
    /// Bot session id used for the single-instance guarantee in Phase 2.
    #[allow(dead_code)]
    bot_session_id: String,
}

impl BotMergePath {
    /// Construct a stub executor. Phase 2 will bind a socket here in
    /// the same shape as [`crate::manual_ship::ManualShipPath`].
    pub fn new(
        intent: ShipIntent<'static>,
        repo_root: impl AsRef<Path>,
        bot_session_id: impl Into<String>,
    ) -> Result<Self, ShipError> {
        Ok(BotMergePath {
            intent,
            repo_root: repo_root.as_ref().to_path_buf(),
            bot_session_id: bot_session_id.into(),
        })
    }
}

#[async_trait]
impl Ship for BotMergePath {
    fn intent(&self) -> &ShipIntent<'_> {
        &self.intent
    }

    async fn preflight(&self) -> Result<PreflightReport, ShipError> {
        // Phase 1 stub: return an empty (all-passed-vacuously) report so
        // callers exercising the trait surface don't blow up. The real
        // gates land in Phase 2 alongside the executor body.
        Ok(PreflightReport { gates: vec![] })
    }

    async fn ship(&self) -> Result<ShipReceipt, ShipError> {
        Err(ShipError::BotMergeDoubleInstance {
            detail: format!(
                "BotMergePath is STUBBED in INFRA-2001 Phase 1. \
                 Fall back to the bash callsite `scripts/coord/bot-merge.sh` \
                 (3044 LOC) for autonomous bot-merge. Phase 2 sub-gap will \
                 port the body. gap_id={}",
                self.intent.gap_id
            ),
        })
    }
}

// ---- Tests --------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[tokio::test]
    async fn ship_returns_stub_error() {
        let tmp = TempDir::new().unwrap();
        let intent = ShipIntent::owned("INFRA-X", "b", "main", "msg", "sess-bm");
        let bm = BotMergePath::new(intent, tmp.path(), "worker-1").expect("ctor");
        let result = bm.ship().await;
        match result {
            Err(ShipError::BotMergeDoubleInstance { detail }) => {
                assert!(
                    detail.contains("STUBBED"),
                    "stub diagnostic should explain: {detail}"
                );
            }
            other => panic!("expected BotMergeDoubleInstance (stub), got {other:?}"),
        }
    }

    #[tokio::test]
    async fn preflight_passes_vacuously() {
        let tmp = TempDir::new().unwrap();
        let intent = ShipIntent::owned("INFRA-X", "b", "main", "msg", "sess-bm");
        let bm = BotMergePath::new(intent, tmp.path(), "worker-1").expect("ctor");
        let report = bm.preflight().await.expect("preflight");
        assert!(report.all_passed());
        assert!(report.gates.is_empty());
    }

    #[test]
    fn intent_accessor_returns_inner() {
        let tmp = TempDir::new().unwrap();
        let intent = ShipIntent::owned("INFRA-Y", "b2", "main", "msg", "sess-bm");
        let bm = BotMergePath::new(intent, tmp.path(), "worker-1").expect("ctor");
        assert_eq!(&*bm.intent().gap_id, "INFRA-Y");
    }
}
