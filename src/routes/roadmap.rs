//! INFRA-1338: `GET /api/roadmap` — server-side ROADMAP.md parser with 60s cache.
//!
//! Replaces the client-side markdown parsing fallback in the PWA's
//! `<chump-view-roadmap>` component (INFRA-1207). Parses
//! `docs/ROADMAP.md` once per 60s via `OnceLock<RwLock<Snapshot>>`, then
//! serves the cached snapshot. If the file is missing or unparseable,
//! returns `200` with `milestones: []` plus a `roadmap_error` string — the
//! frontend already renders an empty/error placeholder gracefully, and a
//! 500 here would mean the entire Roadmap tab disappears on the first
//! transient FS error.
//!
//! Shape (matches what `web/v2/app.js#chump-view-roadmap` consumes):
//! ```json
//! {
//!   "milestones": [
//!     {
//!       "id": "week-1",
//!       "title": "Week 1 — User-facing front door (May 6 → 13) ✅ SHIPPED",
//!       "status": "done" | "active" | "next" | "blocked" | "unknown",
//!       "target_date": null,
//!       "progress_pct": 100,
//!       "done_ratio": 1.0,
//!       "gaps": [{"id":"INFRA-593","title":"","status":"shipped"}, …],
//!       "blockers": []
//!     }
//!   ],
//!   "generated_at_iso": "2026-05-22T23:30:00Z",
//!   "cache_age_secs": 0,
//!   "roadmap_error": null
//! }
//! ```
//!
//! Cache idempotency: a second call within `CACHE_TTL_SECS` returns the
//! same `generated_at_iso`. This is what `scripts/ci/test-api-roadmap.sh`
//! asserts.

use axum::Json;
use std::sync::{OnceLock, RwLock};
use std::time::Instant;

const CACHE_TTL_SECS: u64 = 60;

#[derive(Clone)]
struct Snapshot {
    body: serde_json::Value,
    built_at: Instant,
}

fn cache() -> &'static RwLock<Option<Snapshot>> {
    static CACHE: OnceLock<RwLock<Option<Snapshot>>> = OnceLock::new();
    CACHE.get_or_init(|| RwLock::new(None))
}

/// Test-only hook to flush the cache between assertions.
#[cfg(test)]
fn reset_cache_for_tests() {
    if let Ok(mut g) = cache().write() {
        *g = None;
    }
}

pub async fn handle_roadmap() -> Json<serde_json::Value> {
    // Fast path: cache is warm and within TTL.
    if let Ok(guard) = cache().read() {
        if let Some(snap) = guard.as_ref() {
            if snap.built_at.elapsed().as_secs() < CACHE_TTL_SECS {
                let mut body = snap.body.clone();
                if let Some(obj) = body.as_object_mut() {
                    obj.insert(
                        "cache_age_secs".to_string(),
                        serde_json::json!(snap.built_at.elapsed().as_secs()),
                    );
                }
                return Json(body);
            }
        }
    }

    // Slow path: rebuild snapshot.
    let body = build_snapshot();
    if let Ok(mut guard) = cache().write() {
        *guard = Some(Snapshot {
            body: body.clone(),
            built_at: Instant::now(),
        });
    }
    Json(body)
}

fn build_snapshot() -> serde_json::Value {
    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(p) if !p.trim().is_empty() => std::path::PathBuf::from(p),
        _ => crate::repo_path::runtime_base(),
    };
    let roadmap_path = repo_root.join("docs").join("ROADMAP.md");

    let content = match std::fs::read_to_string(&roadmap_path) {
        Ok(s) => s,
        Err(e) => {
            return serde_json::json!({
                "milestones": [],
                "generated_at_iso": current_iso8601(),
                "cache_age_secs": 0,
                "roadmap_error": format!(
                    "roadmap file unreadable at {}: {}",
                    roadmap_path.display(),
                    e
                ),
            });
        }
    };

    let milestones = parse_milestones(&content);
    let parse_error = if milestones.is_empty() && !content.is_empty() {
        Some(format!(
            "roadmap had {} bytes but no parseable milestones; check '## Week N' / '## Phase N' headings",
            content.len()
        ))
    } else {
        None
    };

    serde_json::json!({
        "milestones": milestones,
        "generated_at_iso": current_iso8601(),
        "cache_age_secs": 0,
        "roadmap_error": parse_error,
    })
}

/// Parse `docs/ROADMAP.md` into the JSON-ready milestone shape the frontend wants.
///
/// We piggyback on `crate::roadmap_status::parse_roadmap` for the `## Week N`
/// extraction (battle-tested by INFRA-606/1145), then translate each week into a
/// frontend-friendly milestone shape with derived `status` + `done_ratio`.
fn parse_milestones(content: &str) -> Vec<serde_json::Value> {
    use crate::roadmap_status::{parse_roadmap, RoadmapGap};

    let mut out: Vec<serde_json::Value> = Vec::new();

    // 1) Week-style milestones (existing parser).
    let weeks = parse_roadmap(content);
    let store = open_gap_store_quiet();
    let (open_ids, done_ids) = collect_gap_id_sets(store.as_ref());

    for week in weeks {
        // Promote each gap's status from the registry when we can.
        let enriched_gaps: Vec<RoadmapGap> = week
            .gaps
            .into_iter()
            .map(|mut g| {
                if !g.is_placeholder {
                    if done_ids.contains(&g.id) {
                        g.status = "shipped".to_string();
                    } else if open_ids.contains(&g.id) {
                        g.status = "open".to_string();
                    }
                }
                g
            })
            .collect();

        let (done_ratio, progress_pct) = compute_done_ratio(&enriched_gaps);
        let status = derive_milestone_status(&week.week_title, &enriched_gaps, done_ratio);

        let gaps_json: Vec<serde_json::Value> = enriched_gaps
            .iter()
            .map(|g| {
                serde_json::json!({
                    "id": g.id,
                    "title": "",
                    "status": g.status,
                    "is_placeholder": g.is_placeholder,
                })
            })
            .collect();

        out.push(serde_json::json!({
            "id": format!("week-{}", week.week),
            "title": format!("Week {} — {}", week.week, week.week_title)
                .trim_end_matches(" — ")
                .to_string(),
            "status": status,
            "target_date": null,
            "progress_pct": progress_pct,
            "done_ratio": done_ratio,
            "gaps": gaps_json,
            "blockers": [],
            "outcome": week.outcome,
        }));
    }

    out
}

fn open_gap_store_quiet() -> Option<crate::gap_store::GapStore> {
    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(p) if !p.trim().is_empty() => std::path::PathBuf::from(p),
        _ => crate::repo_path::runtime_base(),
    };
    crate::gap_store::GapStore::open(&repo_root).ok()
}

fn collect_gap_id_sets(
    store: Option<&crate::gap_store::GapStore>,
) -> (
    std::collections::HashSet<String>,
    std::collections::HashSet<String>,
) {
    let mut open_ids = std::collections::HashSet::new();
    let mut done_ids = std::collections::HashSet::new();
    if let Some(gs) = store {
        if let Ok(rows) = gs.list(Some("open")) {
            for r in rows {
                open_ids.insert(r.id);
            }
        }
        if let Ok(rows) = gs.list(Some("done")) {
            for r in rows {
                done_ids.insert(r.id);
            }
        }
    }
    (open_ids, done_ids)
}

fn compute_done_ratio(gaps: &[crate::roadmap_status::RoadmapGap]) -> (f64, Option<u32>) {
    let real: Vec<_> = gaps.iter().filter(|g| !g.is_placeholder).collect();
    if real.is_empty() {
        return (0.0, None);
    }
    let shipped = real.iter().filter(|g| g.status == "shipped").count();
    let ratio = shipped as f64 / real.len() as f64;
    let pct = (ratio * 100.0).round() as u32;
    (ratio, Some(pct))
}

fn derive_milestone_status(
    title: &str,
    gaps: &[crate::roadmap_status::RoadmapGap],
    done_ratio: f64,
) -> &'static str {
    // Title-tag wins: roadmap authors annotate explicit states.
    let lower = title.to_lowercase();
    if title.contains("\u{2705}") || lower.contains("shipped") || lower.contains("done") {
        return "done";
    }
    if title.contains("\u{1f3d7}") || lower.contains("in progress") || lower.contains("in-progress")
    {
        return "active";
    }
    if lower.contains("blocked") || lower.contains("blocker") {
        return "blocked";
    }
    // Otherwise infer from gap-status mix.
    if !gaps.is_empty() && done_ratio >= 1.0 {
        return "done";
    }
    if done_ratio > 0.0 {
        return "active";
    }
    if gaps.is_empty() {
        return "unknown";
    }
    "next"
}

fn current_iso8601() -> String {
    use chrono::Utc;
    Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = "## Week 1 \u{2014} User-facing front door (May 6 \u{2192} 13) \u{2705} SHIPPED\n\n**Outcome.** A solo dev with Ollama can run chump gen and get a working PR.\n\n**Implementing gaps:**\n- **INFRA-100** \u{2014} gap one (P0 m, pickable)\n- **INFRA-101** \u{2014} gap two (P1 s, in flight #1000)\n- **INFRA-NEW** \u{2014} gap three \u{2014} to be filed\n\n---\n\n## Week 3 \u{2014} Orchestrator MVP (May 22 \u{2192} 28) \u{1f3d7} IN PROGRESS\n\n**Outcome.** Operator types `chump orchestrate`.\n\n**Implementing gaps:**\n- **INFRA-200** \u{2014} gap (P1 m)\n";

    #[test]
    fn test_parse_milestones_count() {
        let ms = parse_milestones(FIXTURE);
        assert_eq!(ms.len(), 2, "expected 2 milestones, got {}", ms.len());
    }

    #[test]
    fn test_milestone_status_from_title_tag() {
        let ms = parse_milestones(FIXTURE);
        // First milestone has the ✅ tag → must be "done"
        assert_eq!(ms[0]["status"], "done");
        // Second has 🏗️ → "active"
        assert_eq!(ms[1]["status"], "active");
    }

    #[test]
    fn test_milestone_id_format() {
        let ms = parse_milestones(FIXTURE);
        assert_eq!(ms[0]["id"], "week-1");
        assert_eq!(ms[1]["id"], "week-3");
    }

    #[test]
    fn test_milestone_has_gaps_array() {
        let ms = parse_milestones(FIXTURE);
        let gaps = ms[0]["gaps"].as_array().unwrap();
        assert!(gaps.len() >= 2, "Week 1 should have ≥2 gaps");
        // Each gap should expose id + status
        for g in gaps {
            assert!(g.get("id").and_then(|v| v.as_str()).is_some());
            assert!(g.get("status").and_then(|v| v.as_str()).is_some());
        }
    }

    #[test]
    fn test_milestone_done_ratio_present() {
        let ms = parse_milestones(FIXTURE);
        // done_ratio is a number in [0.0, 1.0]
        let r = ms[0]["done_ratio"].as_f64().unwrap();
        assert!((0.0..=1.0).contains(&r), "done_ratio out of range: {r}");
    }

    #[test]
    fn test_empty_input_returns_empty_milestones() {
        let ms = parse_milestones("");
        assert!(ms.is_empty());
    }

    #[test]
    fn test_build_snapshot_contains_required_top_level_keys() {
        let snap = build_snapshot();
        let obj = snap.as_object().unwrap();
        assert!(obj.contains_key("milestones"));
        assert!(obj.contains_key("generated_at_iso"));
        assert!(obj.contains_key("cache_age_secs"));
        assert!(obj.contains_key("roadmap_error"));
    }

    #[tokio::test]
    async fn test_cache_idempotency_within_ttl() {
        reset_cache_for_tests();
        let first = handle_roadmap().await;
        let first_ts = first
            .as_object()
            .and_then(|o| o.get("generated_at_iso"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_default();

        // Second call must return the same generated_at_iso (within TTL).
        let second = handle_roadmap().await;
        let second_ts = second
            .as_object()
            .and_then(|o| o.get("generated_at_iso"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_default();
        assert_eq!(
            first_ts, second_ts,
            "cache should return same generated_at_iso on second call"
        );
    }

    #[test]
    fn test_missing_file_returns_error_field_not_panic() {
        // Set CHUMP_REPO to a nonexistent dir so docs/ROADMAP.md cannot be read.
        let prev = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", "/tmp/__chump_infra_1338_nonexistent_dir__");
        let snap = build_snapshot();
        // Restore (best effort).
        if let Some(p) = prev {
            std::env::set_var("CHUMP_REPO", p);
        } else {
            std::env::remove_var("CHUMP_REPO");
        }
        let obj = snap.as_object().unwrap();
        assert_eq!(obj["milestones"].as_array().unwrap().len(), 0);
        let err = obj["roadmap_error"].as_str().unwrap();
        assert!(
            err.contains("unreadable"),
            "expected roadmap_error to mention unreadable: {err}"
        );
    }
}
