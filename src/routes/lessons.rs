//! META-080 (META-073 slice) — in-memory lesson-sharing endpoint.
//!
//! Lets agents POST a lesson tagged with a task, and GET back the
//! lessons relevant to a given tag. Deliberately in-memory (no sqlite
//! table, no ambient event) — this is the minimal slice that proves the
//! sharing shape before META-073 decides whether it graduates to a
//! durable store.
//!
//! Expiry: each lesson expires `TTL_SECS` (24h default) after creation.
//! Expired lessons are pruned lazily on every POST/GET rather than via a
//! background sweep, since the store is process-local and small.

use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const TTL_SECS: u64 = 24 * 60 * 60;

#[derive(Clone, Serialize)]
struct Lesson {
    id: String,
    task_tag: String,
    content: String,
    created_at_iso: String,
    #[serde(skip)]
    expires_at: Instant,
}

fn store() -> &'static Mutex<Vec<Lesson>> {
    static STORE: OnceLock<Mutex<Vec<Lesson>>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(Vec::new()))
}

#[derive(Deserialize)]
pub struct PostLessonBody {
    task_tag: String,
    content: String,
}

pub async fn handle_post_lesson(
    Json(body): Json<PostLessonBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    let task_tag = body.task_tag.trim().to_string();
    let content = body.content.trim().to_string();
    if task_tag.is_empty() || content.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "task_tag and content are required"})),
        ));
    }

    let lesson = Lesson {
        id: uuid::Uuid::new_v4().to_string(),
        task_tag,
        content,
        created_at_iso: current_iso8601(),
        expires_at: Instant::now() + Duration::from_secs(TTL_SECS),
    };

    let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
    prune_expired(&mut guard);
    guard.push(lesson.clone());

    Ok(Json(serde_json::json!({
        "id": lesson.id,
        "task_tag": lesson.task_tag,
        "content": lesson.content,
        "created_at_iso": lesson.created_at_iso,
    })))
}

pub async fn handle_get_lessons(
    Query(params): Query<HashMap<String, String>>,
) -> Json<serde_json::Value> {
    let tag_filter = params.get("tag").map(|s| s.trim().to_string());

    let mut guard = store().lock().unwrap_or_else(|e| e.into_inner());
    prune_expired(&mut guard);

    let lessons: Vec<serde_json::Value> = guard
        .iter()
        .filter(|l| match &tag_filter {
            Some(tag) if !tag.is_empty() => &l.task_tag == tag,
            _ => true,
        })
        .map(|l| {
            serde_json::json!({
                "id": l.id,
                "task_tag": l.task_tag,
                "content": l.content,
                "created_at_iso": l.created_at_iso,
            })
        })
        .collect();

    Json(serde_json::json!({ "lessons": lessons }))
}

fn prune_expired(lessons: &mut Vec<Lesson>) {
    let now = Instant::now();
    lessons.retain(|l| l.expires_at > now);
}

fn current_iso8601() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reset_store() {
        store().lock().unwrap_or_else(|e| e.into_inner()).clear();
    }

    #[tokio::test]
    async fn test_post_then_get_by_tag() {
        reset_store();
        let post_res = handle_post_lesson(Json(PostLessonBody {
            task_tag: "rust-clippy".to_string(),
            content: "always run cargo fmt before clippy".to_string(),
        }))
        .await
        .expect("post should succeed");
        assert_eq!(post_res.0["task_tag"], "rust-clippy");

        let mut params = HashMap::new();
        params.insert("tag".to_string(), "rust-clippy".to_string());
        let get_res = handle_get_lessons(Query(params)).await;
        let lessons = get_res.0["lessons"].as_array().unwrap();
        assert_eq!(lessons.len(), 1);
        assert_eq!(lessons[0]["content"], "always run cargo fmt before clippy");
    }

    #[tokio::test]
    async fn test_get_filters_out_other_tags() {
        reset_store();
        let _ = handle_post_lesson(Json(PostLessonBody {
            task_tag: "tag-a".to_string(),
            content: "lesson a".to_string(),
        }))
        .await
        .unwrap();
        let _ = handle_post_lesson(Json(PostLessonBody {
            task_tag: "tag-b".to_string(),
            content: "lesson b".to_string(),
        }))
        .await
        .unwrap();

        let mut params = HashMap::new();
        params.insert("tag".to_string(), "tag-a".to_string());
        let get_res = handle_get_lessons(Query(params)).await;
        let lessons = get_res.0["lessons"].as_array().unwrap();
        assert_eq!(lessons.len(), 1);
        assert_eq!(lessons[0]["task_tag"], "tag-a");
    }

    #[tokio::test]
    async fn test_post_rejects_empty_fields() {
        reset_store();
        let err = handle_post_lesson(Json(PostLessonBody {
            task_tag: "".to_string(),
            content: "content".to_string(),
        }))
        .await
        .unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn test_expired_lessons_pruned() {
        reset_store();
        {
            let mut guard = store().lock().unwrap();
            guard.push(Lesson {
                id: "expired-1".to_string(),
                task_tag: "tag-a".to_string(),
                content: "stale".to_string(),
                created_at_iso: current_iso8601(),
                expires_at: Instant::now() - Duration::from_secs(1),
            });
        }

        let get_res = handle_get_lessons(Query(HashMap::new())).await;
        let lessons = get_res.0["lessons"].as_array().unwrap();
        assert!(lessons.is_empty(), "expired lesson should be pruned");
    }
}
