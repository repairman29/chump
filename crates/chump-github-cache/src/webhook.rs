//! Webhook receiver-side glue (Phase 1).
//!
//! `chump-webhook-receiver` mounts these axum handlers on
//! `$CHUMP_WEBHOOK_RUST_PORT` (default 9876). The Python receiver keeps
//! running on its own port (9097) during the parallel-validation window.
//!
//! ## Phase 1 scope
//!
//! Only the **HMAC verification + event routing + DB upsert** path is
//! implemented. Sibling features that the Python receiver carries
//! (auto-lease-release on merge, auto-worktree-prune, ambient emission)
//! are deliberately NOT ported in this PR — they live in the Python
//! receiver until follow-up sub-gaps under META-107 port them too.
//!
//! ## Security
//!
//! The receiver verifies `X-Hub-Signature-256` against
//! `CHUMP_WEBHOOK_SECRET` using HMAC-SHA256 constant-time compare. Any
//! mismatch returns HTTP 401 with no body — same posture as the Python
//! receiver (`_verify_signature`).

use std::sync::Arc;

use axum::{
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode},
    routing::{get, post},
    Router,
};
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;

use crate::{
    schema::{CheckRunWebhookPayload, PullRequestWebhookPayload, WorkflowRunWebhookPayload},
    CheckRun, PrState, SqliteCache,
};

type HmacSha256 = Hmac<Sha256>;

/// Per-process state passed to axum handlers.
///
/// Holds the open [`SqliteCache`] (so handlers don't reopen the DB per
/// request) and the HMAC secret (used to verify `X-Hub-Signature-256`).
#[derive(Clone)]
pub struct WebhookState {
    /// Shared cache handle. `SqliteCache` is `Send + Sync` thanks to
    /// the internal `Mutex<Connection>`.
    pub cache: Arc<SqliteCache>,
    /// HMAC secret (from `CHUMP_WEBHOOK_SECRET`). Empty means
    /// "verification disabled" — the handler will refuse to process
    /// anything if this is empty (fail-closed, matches Python receiver).
    pub secret: String,
}

/// Build the axum router used by `chump-webhook-receiver`.
///
/// Routes:
///   - `GET  /healthz` → `200 OK` (liveness)
///   - `POST /github/webhook` → handle event (HMAC-verified)
pub fn router(state: WebhookState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/github/webhook", post(receive_webhook))
        .with_state(state)
}

async fn healthz() -> &'static str {
    "ok"
}

async fn receive_webhook(
    State(state): State<WebhookState>,
    headers: HeaderMap,
    body: Bytes,
) -> (StatusCode, &'static str) {
    // Step 1: HMAC verification.
    let sig = headers
        .get("x-hub-signature-256")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if !verify_signature(&state.secret, &body, sig) {
        tracing::warn!(
            sig_present = !sig.is_empty(),
            secret_present = !state.secret.is_empty(),
            "webhook signature verification failed"
        );
        return (StatusCode::UNAUTHORIZED, "bad signature");
    }

    // Step 2: dispatch by X-GitHub-Event header.
    let event = headers
        .get("x-github-event")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let now = chrono_like_now();

    match event {
        "pull_request" => {
            let payload: PullRequestWebhookPayload = match serde_json::from_slice(&body) {
                Ok(p) => p,
                Err(err) => {
                    tracing::warn!(%err, "failed to decode pull_request payload");
                    return (StatusCode::BAD_REQUEST, "decode failure");
                }
            };
            let pr = pr_payload_to_pr_state(payload.pull_request, &body, &now);
            if let Err(err) = state.cache.upsert_pr(&pr) {
                tracing::warn!(%err, "upsert_pr failed");
                return (StatusCode::INTERNAL_SERVER_ERROR, "db error");
            }
            (StatusCode::OK, "pr upserted")
        }
        "check_run" => {
            let payload: CheckRunWebhookPayload = match serde_json::from_slice(&body) {
                Ok(p) => p,
                Err(err) => {
                    tracing::warn!(%err, "failed to decode check_run payload");
                    return (StatusCode::BAD_REQUEST, "decode failure");
                }
            };
            let run = CheckRun {
                head_sha: payload.check_run.head_sha,
                name: payload.check_run.name,
                status: payload.check_run.status,
                conclusion: payload.check_run.conclusion,
                started_at: payload.check_run.started_at,
                completed_at: payload.check_run.completed_at,
                fetched_at_local: now.clone(),
            };
            if let Err(err) = state.cache.upsert_check_run(&run) {
                tracing::warn!(%err, "upsert_check_run failed");
                return (StatusCode::INTERNAL_SERVER_ERROR, "db error");
            }
            (StatusCode::OK, "check_run upserted")
        }
        "workflow_run" => {
            let payload: WorkflowRunWebhookPayload = match serde_json::from_slice(&body) {
                Ok(p) => p,
                Err(err) => {
                    tracing::warn!(%err, "failed to decode workflow_run payload");
                    return (StatusCode::BAD_REQUEST, "decode failure");
                }
            };
            // Phase 1: persist workflow_run as one check_runs row keyed
            // by `(head_sha, name=workflow_run.name)`. This mirrors how
            // the Python receiver treats workflow_run.completed as a
            // coarse-grained check signal.
            let run = CheckRun {
                head_sha: payload.workflow_run.head_sha,
                name: payload.workflow_run.name,
                status: payload.workflow_run.status,
                conclusion: payload.workflow_run.conclusion,
                started_at: payload.workflow_run.run_started_at,
                completed_at: payload.workflow_run.updated_at,
                fetched_at_local: now.clone(),
            };
            if let Err(err) = state.cache.upsert_check_run(&run) {
                tracing::warn!(%err, "upsert_check_run failed (workflow_run)");
                return (StatusCode::INTERNAL_SERVER_ERROR, "db error");
            }
            (StatusCode::OK, "workflow_run upserted")
        }
        // All other event types: log + drop. Matches Python receiver
        // policy of "200-OK ignored".
        other => {
            tracing::debug!(event = %other, "dropping unhandled event");
            (StatusCode::OK, "ignored")
        }
    }
}

/// Constant-time HMAC-SHA256 verification.
///
/// `sig_header` must be of the form `sha256=<hex>` (GitHub's
/// `X-Hub-Signature-256` shape). Returns `false` on any mismatch,
/// missing-secret, missing-header, or malformed-header case.
pub fn verify_signature(secret: &str, body: &[u8], sig_header: &str) -> bool {
    if secret.is_empty() {
        return false;
    }
    let expected_hex = match sig_header.strip_prefix("sha256=") {
        Some(h) => h,
        None => return false,
    };
    let expected_bytes = match hex::decode(expected_hex) {
        Ok(b) => b,
        Err(_) => return false,
    };
    let mut mac = match HmacSha256::new_from_slice(secret.as_bytes()) {
        Ok(m) => m,
        Err(_) => return false,
    };
    mac.update(body);
    mac.verify_slice(&expected_bytes).is_ok()
}

/// Project a webhook PR payload + raw body into a [`PrState`] row.
fn pr_payload_to_pr_state(
    pr: crate::schema::PrPayloadPr,
    raw_body: &[u8],
    now_iso: &str,
) -> PrState {
    let head = pr.head.as_ref();
    let base = pr.base.as_ref();
    // GitHub sends auto_merge as either an object (enabled) or null. The
    // Python receiver treats "truthy => enabled".
    let auto_merge_enabled = matches!(pr.auto_merge, Some(serde_json::Value::Object(_)));
    PrState {
        number: pr.number,
        head_ref: head.and_then(|h| h.ref_.clone()),
        head_sha: head.and_then(|h| h.sha.clone()),
        base_ref: base.and_then(|b| b.ref_.clone()),
        base_sha: base.and_then(|b| b.sha.clone()),
        mergeable_state: pr.mergeable_state.clone(),
        auto_merge_enabled,
        draft: pr.draft,
        merged_at: pr.merged_at,
        title: pr.title,
        user_login: pr.user.and_then(|u| u.login),
        updated_at_api: pr.updated_at.unwrap_or_else(|| now_iso.to_string()),
        fetched_at_local: now_iso.to_string(),
        raw_payload_json: Some(String::from_utf8_lossy(raw_body).into_owned()),
        merge_state_status: pr.mergeable_state,
    }
}

/// `chrono`-free ISO-8601 UTC stamp generator.
///
/// We avoid pulling a chrono dependency just for this one timestamp;
/// `std::time::SystemTime` + arithmetic is enough.
fn chrono_like_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let dur = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let secs = dur.as_secs() as i64;
    // Days since epoch, then year/month/day decomposition (civil calendar).
    let days = secs.div_euclid(86_400);
    let secs_of_day = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    let h = secs_of_day / 3600;
    let mi = (secs_of_day % 3600) / 60;
    let s = secs_of_day % 60;
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, h, mi, s)
}

/// Public-domain Howard Hinnant civil-from-days conversion.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

// ---- Tests --------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verify_signature_rejects_empty_secret() {
        assert!(!verify_signature("", b"body", "sha256=abc"));
    }

    #[test]
    fn verify_signature_rejects_missing_prefix() {
        assert!(!verify_signature("secret", b"body", "abc"));
    }

    #[test]
    fn verify_signature_rejects_bad_hex() {
        assert!(!verify_signature("secret", b"body", "sha256=zz"));
    }

    #[test]
    fn verify_signature_accepts_valid() {
        // Compute a known-good signature.
        let secret = "supersecret";
        let body = b"hello world";
        let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(body);
        let expected = mac.finalize().into_bytes();
        let sig = format!("sha256={}", hex::encode(expected));
        assert!(verify_signature(secret, body, &sig));
    }

    #[test]
    fn verify_signature_rejects_tampered_body() {
        let secret = "k";
        let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(b"original");
        let sig = format!("sha256={}", hex::encode(mac.finalize().into_bytes()));
        assert!(!verify_signature(secret, b"tampered", &sig));
    }

    #[test]
    fn iso_timestamp_is_well_formed() {
        let t = chrono_like_now();
        // 2026-05-25T19:46:14Z shape: 20 chars, 'T' at idx 10, 'Z' at end.
        assert_eq!(t.len(), 20);
        assert!(t.contains('T'));
        assert!(t.ends_with('Z'));
    }

    #[test]
    fn pr_payload_projects_auto_merge_object_as_enabled() {
        let pr = crate::schema::PrPayloadPr {
            number: 7,
            head: None,
            base: None,
            merged_at: None,
            title: None,
            mergeable_state: None,
            user: None,
            auto_merge: Some(serde_json::json!({"merge_method": "squash"})),
            draft: false,
            updated_at: None,
        };
        let row = pr_payload_to_pr_state(pr, b"{}", "2026-01-01T00:00:00Z");
        assert!(row.auto_merge_enabled);
    }

    #[test]
    fn pr_payload_projects_auto_merge_null_as_disabled() {
        let pr = crate::schema::PrPayloadPr {
            number: 8,
            head: None,
            base: None,
            merged_at: None,
            title: None,
            mergeable_state: None,
            user: None,
            auto_merge: None,
            draft: false,
            updated_at: None,
        };
        let row = pr_payload_to_pr_state(pr, b"{}", "2026-01-01T00:00:00Z");
        assert!(!row.auto_merge_enabled);
    }

    #[test]
    fn pr_payload_uses_now_when_updated_at_missing() {
        let pr = crate::schema::PrPayloadPr {
            number: 9,
            head: None,
            base: None,
            merged_at: None,
            title: None,
            mergeable_state: None,
            user: None,
            auto_merge: None,
            draft: false,
            updated_at: None,
        };
        let row = pr_payload_to_pr_state(pr, b"{}", "2026-01-01T00:00:00Z");
        assert_eq!(row.updated_at_api, "2026-01-01T00:00:00Z");
    }

    #[test]
    fn schema_tolerates_extra_unknown_fields() {
        // Synthetic payload with an extra top-level field GitHub may
        // someday add. Must still parse (Phase 1 deserialization is
        // forgiving).
        let body = serde_json::json!({
            "action": "opened",
            "future_field_chump_doesnt_know_about": {"x": 1},
            "pull_request": {
                "number": 99,
                "title": "feat: something",
                "draft": false,
                "another_unknown_subfield": [1, 2, 3]
            }
        });
        let p: PullRequestWebhookPayload = serde_json::from_value(body).expect("tolerant decode");
        assert_eq!(p.action, "opened");
        assert_eq!(p.pull_request.number, 99);
    }
}
