//! INFRA-1563: `GET /api/decisions` + `POST /api/decisions/{id}/resolve` —
//! operator-decision queue backend. Sibling to `routes::roadmap` (INFRA-1338).
//!
//! Source of truth is `.chump-locks/ambient.jsonl`: the orchestrator/picker/
//! bot-merge emit `kind=operator_decision_needed` when they need operator
//! input (demote/promote a gap, approve a merge, clarify scope). A decision
//! is "pending" until a matching `kind=operator_decision_resolved` event with
//! the same `id` appears later in the stream.
//!
//! Response shape (matches `web/v2/app.js#chump-view-decisions`):
//! ```json
//! [
//!   {
//!     "id": "dec-abc123",
//!     "kind": <gap_demote / gap_promote / merge_approval / scope_clarify>,
//!     "gap_id": "INFRA-1234",
//!     "pr_number": 4821,
//!     "summary": "PR #4821 touches auth middleware — needs operator sign-off",
//!     "priority": "P1",
//!     "created_at": "2026-09-25T12:00:00Z"
//!   }
//! ]
//! ```

use axum::extract::Path;
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use std::io::Write;
use std::path::PathBuf;

fn ambient_log_path() -> PathBuf {
    std::env::var("CHUMP_AMBIENT_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            crate::repo_path::runtime_base()
                .join(".chump-locks")
                .join("ambient.jsonl")
        })
}

/// GET /api/decisions — pending operator decisions, newest first.
pub async fn handle_decisions_list() -> Json<serde_json::Value> {
    Json(serde_json::json!(build_pending_decisions()))
}

fn build_pending_decisions() -> Vec<serde_json::Value> {
    let content = match std::fs::read_to_string(ambient_log_path()) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };

    let mut needed: Vec<serde_json::Value> = Vec::new();
    let mut resolved_ids: std::collections::HashSet<String> = std::collections::HashSet::new();

    for line in content.lines() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let kind = v.get("kind").and_then(|k| k.as_str()).unwrap_or("");
        match kind {
            "operator_decision_needed" => needed.push(v),
            "operator_decision_resolved" => {
                if let Some(id) = v.get("id").and_then(|k| k.as_str()) {
                    resolved_ids.insert(id.to_string());
                }
            }
            _ => {}
        }
    }

    needed
        .into_iter()
        .filter(|v| {
            v.get("id")
                .and_then(|k| k.as_str())
                .is_some_and(|id| !resolved_ids.contains(id))
        })
        .map(|v| {
            serde_json::json!({
                "id": v.get("id").and_then(|x| x.as_str()).unwrap_or(""),
                "kind": v.get("decision_kind").and_then(|x| x.as_str()).unwrap_or("scope_clarify"),
                "gap_id": v.get("gap_id").and_then(|x| x.as_str()),
                "pr_number": v.get("pr_number").and_then(|x| x.as_i64()),
                "summary": v.get("summary").and_then(|x| x.as_str()).unwrap_or(""),
                "priority": v.get("priority").and_then(|x| x.as_str()).unwrap_or("P2"),
                "created_at": v.get("ts").and_then(|x| x.as_str()).unwrap_or(""),
            })
        })
        .rev()
        .collect()
}

/// POST /api/decisions/{id}/resolve — writes the operator response back as
/// `kind=operator_decision_resolved`. Body is any JSON object (e.g.
/// `{"response": "approved"}`); it is passed through under `response`.
pub async fn handle_decisions_resolve(
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !crate::routes::shared::check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if id.trim().is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }

    let event = serde_json::json!({
        "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "kind": "operator_decision_resolved",
        "id": id,
        "response": payload,
    });
    let line = serde_json::to_string(&event).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log_path())
    {
        let _ = writeln!(f, "{}", line);
    }

    Ok(Json(serde_json::json!({ "ok": true })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    fn with_temp_ambient<F: FnOnce()>(f: F) {
        let dir =
            std::env::temp_dir().join(format!("chump_infra_1563_test_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("ambient.jsonl");
        let prev = std::env::var("CHUMP_AMBIENT_LOG").ok();
        std::env::set_var("CHUMP_AMBIENT_LOG", &path);
        f();
        let _ = std::fs::remove_file(&path);
        match prev {
            Some(p) => std::env::set_var("CHUMP_AMBIENT_LOG", p),
            None => std::env::remove_var("CHUMP_AMBIENT_LOG"),
        }
    }

    #[test]
    #[serial]
    fn test_missing_ambient_file_returns_empty() {
        with_temp_ambient(|| {
            let decisions = build_pending_decisions();
            assert!(decisions.is_empty());
        });
    }

    #[test]
    #[serial]
    fn test_pending_decision_surfaces() {
        with_temp_ambient(|| {
            let path = ambient_log_path();
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .unwrap();
            writeln!(
                f,
                r#"{{"ts":"2026-09-25T00:00:00Z","kind":"operator_decision_needed","id":"dec-1","decision_kind":"merge_approval","gap_id":"INFRA-1","pr_number":42,"summary":"needs sign-off","priority":"P1"}}"#
            )
            .unwrap();
            let decisions = build_pending_decisions();
            assert_eq!(decisions.len(), 1);
            assert_eq!(decisions[0]["id"], "dec-1");
            assert_eq!(decisions[0]["kind"], "merge_approval");
            assert_eq!(decisions[0]["pr_number"], 42);
        });
    }

    #[test]
    #[serial]
    fn test_resolved_decision_disappears() {
        with_temp_ambient(|| {
            let path = ambient_log_path();
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .unwrap();
            writeln!(
                f,
                r#"{{"ts":"2026-09-25T00:00:00Z","kind":"operator_decision_needed","id":"dec-2","decision_kind":"scope_clarify","summary":"clarify scope","priority":"P2"}}"#
            )
            .unwrap();
            writeln!(
                f,
                r#"{{"ts":"2026-09-25T00:01:00Z","kind":"operator_decision_resolved","id":"dec-2","response":{{"answer":"ok"}}}}"#
            )
            .unwrap();
            let decisions = build_pending_decisions();
            assert!(decisions.is_empty());
        });
    }
}
