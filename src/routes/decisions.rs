//! INFRA-1563: `GET /api/decisions` + `POST /api/decisions/{id}/resolve` —
//! operator-decision queue backend. Sibling to INFRA-1338 (`/api/roadmap`):
//! same shape (scan a local source of truth, serve JSON, never 500 on a
//! missing/empty source).
//!
//! Source of truth: `.chump-locks/ambient.jsonl` `kind=operator_decision_needed`
//! events (emitted by orchestrator/picker/bot-merge when operator input is
//! required), minus any `id` that already has a matching
//! `kind=operator_decision_resolved` event. This mirrors the append-only
//! event-sourcing pattern already used for inbox/broadcast state elsewhere in
//! `web_server.rs` — no new persistence layer.
//!
//! Response shape (matches what `web/v2/app.js#chump-view-decisions` consumes):
//! ```json
//! [
//!   {
//!     "id": "dec-abc123",
//!     "kind": "gap_demote",
//!     "gap_id": "INFRA-1234",
//!     "pr_number": null,
//!     "summary": "Gap has been open 14d with no activity — demote to P3?",
//!     "priority": "normal",
//!     "created_at": "2026-08-27T00:00:00Z"
//!   }
//! ]
//! ```

use axum::extract::Path;
use axum::http::StatusCode;
use axum::Json;
use std::io::Write;

/// `kind` values accepted for `operator_decision_needed.kind`.
pub const VALID_DECISION_KINDS: &[&str] = &[
    "gap_demote",
    "gap_promote",
    "merge_approval",
    "scope_clarify",
];

fn ambient_path() -> std::path::PathBuf {
    crate::repo_path::runtime_base()
        .join(".chump-locks")
        .join("ambient.jsonl")
}

pub async fn handle_decisions_list() -> Json<serde_json::Value> {
    let path = ambient_path();
    let raw = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        // Missing ambient stream just means no decisions have ever been
        // emitted yet — 200 + empty array, never a 500 (same posture as
        // /api/roadmap's missing-file path).
        Err(_) => return Json(serde_json::json!([])),
    };

    let mut needed: Vec<serde_json::Value> = Vec::new();
    let mut resolved_ids = std::collections::HashSet::new();

    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let kind = v.get("kind").and_then(|k| k.as_str()).unwrap_or("");
        match kind {
            "operator_decision_needed" => needed.push(v),
            "operator_decision_resolved" => {
                if let Some(id) = v.get("id").and_then(|i| i.as_str()) {
                    resolved_ids.insert(id.to_string());
                }
            }
            _ => {}
        }
    }

    let pending: Vec<serde_json::Value> = needed
        .into_iter()
        .filter(|d| {
            let id = d.get("id").and_then(|i| i.as_str()).unwrap_or("");
            !id.is_empty() && !resolved_ids.contains(id)
        })
        .map(|d| {
            serde_json::json!({
                "id": d.get("id").cloned().unwrap_or(serde_json::Value::Null),
                "kind": d.get("kind").cloned().unwrap_or(serde_json::Value::Null),
                "gap_id": d.get("gap_id").cloned().unwrap_or(serde_json::Value::Null),
                "pr_number": d.get("pr_number").cloned().unwrap_or(serde_json::Value::Null),
                "summary": d.get("summary").cloned().unwrap_or(serde_json::Value::Null),
                "priority": d.get("priority").cloned().unwrap_or(serde_json::json!("normal")),
                "created_at": d.get("ts").cloned().unwrap_or(serde_json::Value::Null),
            })
        })
        .collect();

    Json(serde_json::Value::Array(pending))
}

#[derive(Debug, serde::Deserialize, Default)]
pub struct ResolveDecisionRequest {
    #[serde(default)]
    pub response: Option<String>,
    #[serde(default)]
    pub resolved_by: Option<String>,
}

pub async fn handle_decisions_resolve(
    Path(id): Path<String>,
    body: Option<Json<ResolveDecisionRequest>>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if id.trim().is_empty() {
        return Err((StatusCode::BAD_REQUEST, "missing decision id".to_string()));
    }
    let body = body.unwrap_or_default().0;

    let event = serde_json::json!({
        "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "kind": "operator_decision_resolved",
        "id": id,
        "response": body.response,
        "resolved_by": body.resolved_by.unwrap_or_else(|| "operator".to_string()),
    });

    let path = ambient_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("mkdir: {e}")))?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("open: {e}")))?;
    writeln!(f, "{}", event)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("write: {e}")))?;

    Ok(Json(serde_json::json!({ "ok": true, "id": id })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn empty_ambient_returns_empty_array() {
        let tmp = tempfile::tempdir().unwrap();
        let prior = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", tmp.path());
        let Json(body) = handle_decisions_list().await;
        match prior {
            Some(v) => std::env::set_var("CHUMP_REPO", v),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        assert_eq!(body, serde_json::json!([]));
    }

    #[tokio::test]
    async fn needed_minus_resolved_filters_correctly() {
        let tmp = tempfile::tempdir().unwrap();
        let locks = tmp.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let ambient = locks.join("ambient.jsonl");
        std::fs::write(
            &ambient,
            concat!(
                r#"{"ts":"2026-08-27T00:00:00Z","kind":"operator_decision_needed","id":"dec-1","gap_demote":false,"summary":"a"}"#,
                "\n",
                r#"{"ts":"2026-08-27T00:00:01Z","kind":"operator_decision_needed","id":"dec-2","summary":"b"}"#,
                "\n",
                r#"{"ts":"2026-08-27T00:00:02Z","kind":"operator_decision_resolved","id":"dec-1"}"#,
                "\n",
            ),
        )
        .unwrap();

        let prior = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", tmp.path());
        let Json(body) = handle_decisions_list().await;
        match prior {
            Some(v) => std::env::set_var("CHUMP_REPO", v),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        let arr = body.as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["id"], "dec-2");
    }
}
