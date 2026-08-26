//! EFFECTIVE-478 (EFFECTIVE-364 slice): publication resolver trigger.
//!
//! `GapStore::ship` fires a [`PublicationEvent`] through [`resolve_publication`]
//! whenever a gap lands — the resolver is the (future) hook that turns a
//! shipped artifact into a published one (release notes, docs site, etc).
//! Today it is a thin, fallible stub: real per-artifact-type publication
//! routing is out of scope for this slice.

use anyhow::{bail, Result};

/// Emitted immediately after a gap transitions to its shipped/done status.
#[derive(Debug, Clone)]
pub struct PublicationEvent {
    pub artifact_type: String,
    pub source_gap_id: String,
}

/// Resolve (route) a shipped gap's artifact to its publication target.
///
/// Best-effort by design: callers (see `GapStore::ship`) log failures via
/// `tracing::error` and never let this block the ship transition itself.
pub async fn resolve_publication(event: PublicationEvent) -> Result<()> {
    if event.artifact_type.is_empty() {
        bail!(
            "publication resolver: gap {} has empty artifact_type",
            event.source_gap_id
        );
    }
    Ok(())
}
