//! INFRA-3618 Substrate S1: best-effort shadow dual-write to `shared_gaps`.
//!
//! Stage 1 of the one-canonical-store permanent fix (S0 stood up the
//! self-hosted Postgres + PostgREST substrate; see `chump-team`). This
//! stage adds a write-only shadow: every gap mutation that already lands
//! in `state.db` additionally gets fired at `shared_gaps` on the shared
//! store. Reads are completely unchanged — state.db remains canonical and
//! is the only thing any caller of `chump-gap-store` ever reads back.
//!
//! ## Safety invariant (AC #2, blocking)
//!
//! The shadow write must never change canonical behavior:
//!   - Gated behind `CHUMP_STORE_SHADOW=1` (default OFF — [`shadow_enabled`]).
//!   - Runs on a **detached background thread** with its own throwaway
//!     tokio runtime, so the canonical `state.db` call this is attached to
//!     returns immediately regardless of network latency, DNS failure, or
//!     PostgREST being down entirely. There is no `.join()`, no channel
//!     the caller waits on — canonical behavior is bit-for-bit identical
//!     with the shadow on or off.
//!   - Any failure (missing env, network, schema mismatch, timeout, HTTP
//!     error) is caught, logged as `kind=shadow_write_failed` to
//!     `ambient.jsonl`, and swallowed. It never panics and never
//!     propagates to the canonical caller.
//!
//! Reversible: setting `CHUMP_STORE_SHADOW=0` (or unsetting it) fully
//! disables this module's effect with zero residue — no thread spawns, no
//! network calls, no files written beyond the (never consulted) ambient
//! log lines already emitted while it was on.

use crate::{unix_now, unix_to_iso_full, GapRow};
use std::io::Write as _;
use std::path::{Path, PathBuf};

/// Is the shadow-write path turned on? Default OFF per AC #4 — this is a
/// tracked toggle (see `docs/process/CAPABILITY_DECISIONS.md`).
pub fn shadow_enabled() -> bool {
    std::env::var("CHUMP_STORE_SHADOW").as_deref() == Ok("1")
}

/// Fire-and-forget shadow write of one gap row to `shared_gaps`. No-op if
/// [`shadow_enabled`] is false. Never blocks the caller — see module docs.
pub fn shadow_write_gap(repo_root: &Path, op: &'static str, row: GapRow) {
    if !shadow_enabled() {
        return;
    }
    let repo_root = repo_root.to_path_buf();
    std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => {
                emit_shadow_failure(&repo_root, &row.id, op, &format!("runtime build: {e}"));
                return;
            }
        };
        rt.block_on(async {
            if let Err(reason) = do_shadow_write(&row).await {
                emit_shadow_failure(&repo_root, &row.id, op, &reason);
            }
        });
    });
}

/// Best-effort env-configured identity for shadow writes. `shared_gaps`
/// requires a non-null `team_id` (FK to `teams`) and `created_by_user_id`;
/// on the self-hosted CJ store both are seeded ahead of time. Falls back to
/// the nil UUID when unset — a fault-injection / not-yet-provisioned case
/// that surfaces as a `shadow_write_failed` FK-violation event rather than
/// panicking.
fn shadow_team_id() -> uuid::Uuid {
    std::env::var("CHUMP_STORE_SHADOW_TEAM_ID")
        .ok()
        .and_then(|s| uuid::Uuid::parse_str(&s).ok())
        .unwrap_or(uuid::Uuid::nil())
}

fn shadow_user_id() -> uuid::Uuid {
    std::env::var("CHUMP_STORE_SHADOW_USER_ID")
        .ok()
        .and_then(|s| uuid::Uuid::parse_str(&s).ok())
        .unwrap_or(uuid::Uuid::nil())
}

/// Map a local `state.db` status string onto the shared-store's closed
/// enum. Unknown / not-yet-modeled local statuses (e.g. `in_review`,
/// `ready_to_ship`) fall back to `Claimed` — the closest "in-flight, not
/// terminal" shared status — since this is a best-effort mirror, not the
/// canonical record.
fn map_status(local: &str) -> chump_team::GapStatus {
    use chump_team::GapStatus;
    match local {
        "open" => GapStatus::Open,
        "done" | "shipped" => GapStatus::Shipped,
        "superseded" | "wontfix" | "wont_fix" | "closed" | "closed_not_a_bug"
        | "already_satisfied" => GapStatus::Superseded,
        "blocked" => GapStatus::Blocked,
        _ => GapStatus::Claimed,
    }
}

fn map_priority(local: &str) -> chump_team::Priority {
    use chump_team::Priority;
    match local {
        "P0" => Priority::P0,
        "P1" => Priority::P1,
        "P2" => Priority::P2,
        _ => Priority::P3,
    }
}

fn map_effort(local: &str) -> chump_team::Effort {
    use chump_team::Effort;
    match local {
        "xs" => Effort::Xs,
        "s" => Effort::S,
        "l" => Effort::L,
        _ => Effort::M,
    }
}

async fn do_shadow_write(row: &GapRow) -> Result<(), String> {
    let client = chump_team::ChumpTeam::from_env().map_err(|e| format!("config: {e}"))?;
    client
        .upsert_gap(
            &row.id,
            shadow_team_id(),
            &row.domain,
            &row.title,
            map_priority(&row.priority),
            map_effort(&row.effort),
            map_status(&row.status),
            shadow_user_id(),
            row.closed_pr.and_then(|v| i32::try_from(v).ok()),
        )
        .await
        .map(|_| ())
        .map_err(|e| format!("upsert_gap: {e}"))
}

/// scanner-anchor: "kind":"shadow_write_failed" (INFRA-3618, registered in
/// docs/observability/EVENT_REGISTRY.yaml)
fn emit_shadow_failure(repo_root: &Path, gap_id: &str, op: &str, reason: &str) {
    let ts = unix_to_iso_full(unix_now());
    let safe_reason = reason.replace('"', "'").replace('\n', " ");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"shadow_write_failed\",\"gap_id\":\"{gap_id}\",\
         \"op\":\"{op}\",\"reason\":\"{safe_reason}\"}}\n"
    );
    let locks_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&locks_dir);
    let amb: PathBuf = locks_dir.join("ambient.jsonl");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shadow_disabled_by_default() {
        std::env::remove_var("CHUMP_STORE_SHADOW");
        assert!(!shadow_enabled());
    }

    #[test]
    fn shadow_status_mapping_covers_terminal_states() {
        assert!(matches!(map_status("open"), chump_team::GapStatus::Open));
        assert!(matches!(map_status("done"), chump_team::GapStatus::Shipped));
        assert!(matches!(
            map_status("superseded"),
            chump_team::GapStatus::Superseded
        ));
        assert!(matches!(
            map_status("blocked"),
            chump_team::GapStatus::Blocked
        ));
        // Unmodeled local status falls back to Claimed rather than panicking.
        assert!(matches!(
            map_status("in_review"),
            chump_team::GapStatus::Claimed
        ));
    }

    #[test]
    fn shadow_priority_and_effort_mapping() {
        assert!(matches!(map_priority("P0"), chump_team::Priority::P0));
        assert!(matches!(map_priority("bogus"), chump_team::Priority::P3));
        assert!(matches!(map_effort("xs"), chump_team::Effort::Xs));
        assert!(matches!(map_effort("bogus"), chump_team::Effort::M));
    }

    #[test]
    fn shadow_team_and_user_id_fallback_to_nil() {
        std::env::remove_var("CHUMP_STORE_SHADOW_TEAM_ID");
        std::env::remove_var("CHUMP_STORE_SHADOW_USER_ID");
        assert_eq!(shadow_team_id(), uuid::Uuid::nil());
        assert_eq!(shadow_user_id(), uuid::Uuid::nil());
    }
}
