//! Health, stack-status, cascade-status, cognitive-state, and favicon handlers.

use axum::http::StatusCode;
use axum::response::sse::{Event, Sse};
use axum::{response::Redirect, Json};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::local_openai;
use crate::provider_cascade;

/// CREDIBLE-022: compute age of the installed binary in seconds since its baked build date.
/// Returns None if the build date is "unknown" or unparseable.
fn binary_age_secs() -> Option<u64> {
    let build_date = crate::version::chump_build_date();
    if build_date == "unknown" {
        return None;
    }
    // build date format: "yyyy-mm-dd"
    let parts: Vec<u32> = build_date
        .split('-')
        .filter_map(|s| s.parse().ok())
        .collect();
    if parts.len() != 3 {
        return None;
    }
    use chrono::{TimeZone, Utc};
    let build_dt = Utc
        .with_ymd_and_hms(parts[0] as i32, parts[1], parts[2], 0, 0, 0)
        .single()?;
    let now = Utc::now();
    let diff = now.signed_duration_since(build_dt);
    if diff.num_seconds() < 0 {
        return Some(0);
    }
    Some(diff.num_seconds() as u64)
}

pub async fn handle_health() -> Json<serde_json::Value> {
    // CREDIBLE-022: version_match — compare running version to optional override env var.
    // In normal deployments the binary IS the server so they always match; operators can
    // set CHUMP_BINARY_VERSION to the version they expect and the endpoint reports the diff.
    let running_version = crate::version::chump_version();
    let expected_version = std::env::var("CHUMP_BINARY_VERSION").ok();
    let version_match = expected_version
        .as_deref()
        .map(|exp| exp == running_version)
        .unwrap_or(true);

    let age_secs = binary_age_secs();

    // INFRA-1004: expose active cascade routing mode so operators can confirm
    // local-only mode is in effect without needing to read env vars.
    let cascade = provider_cascade::ProviderCascade::from_env();
    let cascade_mode = cascade.cascade_mode();

    Json(serde_json::json!({
        "status": "ok",
        "service": "chump-web",
        "binary_version": running_version,
        "build_sha": crate::version::chump_build_sha(),
        "build_date": crate::version::chump_build_date(),
        "binary_age_secs": age_secs,
        "version_match": version_match,
        "cascade_mode": cascade_mode,
    }))
}

/// OpenAI-compatible HTTP `/models` probe only.
async fn probe_openai_http_sidecar(
    openai_base: Option<String>,
    timeout_secs: u64,
) -> serde_json::Value {
    let mut inference = serde_json::json!({
        "configured": openai_base.is_some(),
        "models_reachable": serde_json::Value::Null,
        "http_status": serde_json::Value::Null,
        "probe": serde_json::Value::Null,
        "error": serde_json::Value::Null,
        "models_url": serde_json::Value::Null,
    });

    if let Some(ref base) = openai_base {
        let models_url = format!("{}/models", base);
        inference["models_url"] = serde_json::json!(models_url.clone());
        let is_local = base.contains("127.0.0.1") || base.contains("localhost");
        if !is_local {
            inference["probe"] = serde_json::json!("skipped_non_local");
        } else {
            inference["probe"] = serde_json::json!("local_http");
            let client = match reqwest::Client::builder()
                .timeout(Duration::from_secs(timeout_secs))
                .build()
            {
                Ok(c) => c,
                Err(e) => {
                    inference["error"] = serde_json::json!(format!("client: {}", e));
                    inference["models_reachable"] = serde_json::json!(false);
                    return inference;
                }
            };
            let mut req = client.get(&models_url);
            if let Ok(key) = std::env::var("OPENAI_API_KEY") {
                let k = key.trim();
                if !k.is_empty() && !k.eq_ignore_ascii_case("not-needed") {
                    req = req.header("Authorization", format!("Bearer {}", k));
                }
            }
            match req.send().await {
                Ok(resp) => {
                    let status = resp.status().as_u16();
                    inference["http_status"] = serde_json::json!(status);
                    inference["models_reachable"] = serde_json::json!(resp.status().is_success());
                    if !resp.status().is_success() {
                        let body = resp.text().await.unwrap_or_default();
                        let snippet: String = body.chars().take(180).collect();
                        if !snippet.is_empty() {
                            inference["error"] = serde_json::json!(snippet);
                        }
                    }
                }
                Err(e) => {
                    inference["models_reachable"] = serde_json::json!(false);
                    inference["error"] = serde_json::json!(e.to_string());
                }
            }
        }
    } else {
        inference["error"] = serde_json::json!("OPENAI_API_BASE not set");
        inference["probe"] = serde_json::json!("no_base");
    }

    inference
}

/// GET /api/stack-status
pub async fn handle_stack_status() -> Json<serde_json::Value> {
    let air_gap_mode = crate::env_flags::chump_air_gap_mode();
    let timeout_secs = std::env::var("CHUMP_STACK_PROBE_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| (1..=30).contains(&n))
        .unwrap_or(8);
    let openai_base = std::env::var("OPENAI_API_BASE")
        .ok()
        .map(|s| s.trim().trim_end_matches('/').to_string())
        .filter(|s| !s.is_empty());
    let openai_model = std::env::var("OPENAI_MODEL").ok();
    let cascade_enabled = std::env::var("CHUMP_CASCADE_ENABLED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);

    let mistralrs = crate::env_flags::chump_inference_backend_mistralrs_env();
    let mistralrs_model = std::env::var("CHUMP_MISTRALRS_MODEL")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let openai_http = probe_openai_http_sidecar(openai_base.clone(), timeout_secs).await;

    let inference = if mistralrs {
        serde_json::json!({
            "primary_backend": "mistralrs",
            "configured": true,
            "mistralrs_model": mistralrs_model,
            "probe": "mistralrs_in_process",
            "models_reachable": true,
            "http_status": serde_json::Value::Null,
            "error": serde_json::Value::Null,
            "models_url": serde_json::Value::Null,
            "openai_http_sidecar": openai_http,
        })
    } else {
        let mut inf = openai_http;
        if let Some(obj) = inf.as_object_mut() {
            obj.insert(
                "primary_backend".to_string(),
                serde_json::json!("openai_compatible"),
            );
        }
        inf
    };

    Json(serde_json::json!({
        "status": "ok",
        "service": "chump-web",
        "openai_api_base": openai_base,
        "openai_model": openai_model,
        "inference": inference,
        "cascade_enabled": cascade_enabled,
        "air_gap_mode": air_gap_mode,
        "llm_last_completion": crate::llm_backend_metrics::snapshot_last_json(),
        "llm_completion_totals": crate::llm_backend_metrics::snapshot_totals_json(),
        "cognitive_control": {
            "recommended_max_tool_calls": crate::precision_controller::recommended_max_tool_calls(),
            "recommended_max_delegate_parallel": crate::precision_controller::recommended_max_delegate_parallel(),
            "belief_tool_budget": crate::env_flags::chump_belief_tool_budget(),
            "task_uncertainty": (crate::belief_state::task_belief().uncertainty() * 1000.0).round() / 1000.0,
            "context_exploration_fraction": (crate::precision_controller::context_exploration_budget() * 1000.0).round() / 1000.0,
            "effective_tool_timeout_secs": crate::neuromodulation::effective_tool_timeout_secs(
                crate::tool_middleware::DEFAULT_TOOL_TIMEOUT_SECS,
            ),
        },
        "tool_policy": crate::tool_policy::tool_policy_for_stack_status(),
    }))
}

/// Redirect /favicon.ico to the PWA icon.
pub async fn handle_favicon() -> Redirect {
    Redirect::to("/icon.svg")
}

// ── Cascade slot config.toml helpers (PRODUCT-054) ────────────────────────

fn cascade_config_path() -> std::path::PathBuf {
    let home = std::env::var("CHUMP_HOME")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_else(|_| "/tmp".into());
    std::path::PathBuf::from(home)
        .join(".chump")
        .join("config.toml")
}

/// Read `[cascade_slots] disabled = [...]` from ~/.chump/config.toml.
fn read_cascade_disabled() -> Vec<String> {
    let path = cascade_config_path();
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return vec![],
    };
    let mut in_section = false;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_section = trimmed == "[cascade_slots]";
            continue;
        }
        if !in_section || trimmed.starts_with('#') {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("disabled") {
            let rest = rest
                .trim_start_matches(|c: char| c == '=' || c.is_whitespace())
                .trim_matches(|c: char| c == '[' || c == ']');
            return rest
                .split(',')
                .map(|s| s.trim().trim_matches('"').to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }
    }
    vec![]
}

/// Write `[cascade_slots] disabled = [...]` into ~/.chump/config.toml.
/// Creates the file / section if absent; replaces existing disabled line in place.
fn write_cascade_disabled(disabled: &[String]) -> std::io::Result<()> {
    let path = cascade_config_path();
    let content = std::fs::read_to_string(&path).unwrap_or_default();
    let disabled_line = if disabled.is_empty() {
        "disabled = []".to_string()
    } else {
        let items: Vec<String> = disabled.iter().map(|s| format!("\"{}\"", s)).collect();
        format!("disabled = [{}]", items.join(", "))
    };

    if content.contains("[cascade_slots]") {
        let mut result: Vec<String> = Vec::new();
        let mut in_section = false;
        let mut replaced = false;
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with('[') {
                if in_section && !replaced {
                    result.push(disabled_line.clone());
                    replaced = true;
                }
                in_section = trimmed == "[cascade_slots]";
                result.push(line.to_string());
                continue;
            }
            if in_section && trimmed.starts_with("disabled") {
                result.push(disabled_line.clone());
                replaced = true;
                continue;
            }
            result.push(line.to_string());
        }
        if in_section && !replaced {
            result.push(disabled_line.clone());
        }
        std::fs::write(&path, result.join("\n") + "\n")
    } else {
        let mut new_content = content;
        if !new_content.ends_with('\n') {
            new_content.push('\n');
        }
        new_content.push('\n');
        new_content.push_str("[cascade_slots]\n");
        new_content.push_str(&disabled_line);
        new_content.push('\n');
        std::fs::write(&path, new_content)
    }
}

/// GET /api/cascade-status
pub async fn handle_cascade_status() -> Result<Json<serde_json::Value>, StatusCode> {
    let disabled = read_cascade_disabled();
    let cascade = match provider_cascade::cascade_for_status() {
        Some(c) => c,
        None => {
            let c = provider_cascade::ProviderCascade::from_env();
            if c.slots.is_empty() {
                return Ok(Json(serde_json::json!({ "slots": [], "enabled": false })));
            }
            let budget = provider_cascade::cascade_budget_remaining();
            let remaining_map_none: std::collections::HashMap<String, u32> = budget
                .as_ref()
                .map(|(_, per)| per.iter().cloned().collect())
                .unwrap_or_default();
            let total_remaining_rpd_none = budget.map(|(t, _)| t).unwrap_or(0);
            let slots: Vec<serde_json::Value> = c
                .slots
                .iter()
                .map(|s| {
                    let quality_full = crate::provider_quality::get_quality_full(&s.name);
                    let remaining_rpd = remaining_map_none.get(&s.name).copied();
                    serde_json::json!({
                        "name": s.name,
                        "disabled_by_config": disabled.contains(&s.name),
                        "calls_today": s.calls_today.load(std::sync::atomic::Ordering::Relaxed),
                        "rpd_limit": s.rpd_limit,
                        "remaining_rpd": remaining_rpd,
                        "calls_this_minute": s.calls_this_minute.load(std::sync::atomic::Ordering::Relaxed),
                        "rpm_limit": s.rpm_limit,
                        "circuit_state": local_openai::model_circuit_state(&s.base_url),
                        "success_count": quality_full.map(|q| q.0).unwrap_or(0),
                        "sanity_fail_count": quality_full.map(|q| q.1).unwrap_or(0),
                        "latency_ms_p50": quality_full.and_then(|q| q.2),
                        "latency_ms_p95": quality_full.and_then(|q| q.3),
                        "tool_call_accuracy": quality_full.and_then(|q| q.4),
                    })
                })
                .collect();
            let provider_summary = crate::cost_tracker::provider_daily_summary();
            return Ok(Json(serde_json::json!({
                "slots": slots,
                "enabled": true,
                "provider_summary": provider_summary,
                "total_remaining_rpd": total_remaining_rpd_none
            })));
        }
    };
    let budget = provider_cascade::cascade_budget_remaining();
    let remaining_map: std::collections::HashMap<String, u32> = budget
        .as_ref()
        .map(|(_, per)| per.iter().cloned().collect())
        .unwrap_or_default();
    let total_remaining_rpd = budget.map(|(t, _)| t).unwrap_or(0);

    let slots: Vec<serde_json::Value> = cascade
        .slots
        .iter()
        .map(|s| {
            let quality_full = crate::provider_quality::get_quality_full(&s.name);
            let remaining_rpd = remaining_map.get(&s.name).copied();
            serde_json::json!({
                "name": s.name,
                "disabled_by_config": disabled.contains(&s.name),
                "calls_today": s.calls_today.load(std::sync::atomic::Ordering::Relaxed),
                "rpd_limit": s.rpd_limit,
                "remaining_rpd": remaining_rpd,
                "calls_this_minute": s.calls_this_minute.load(std::sync::atomic::Ordering::Relaxed),
                "rpm_limit": s.rpm_limit,
                "circuit_state": local_openai::model_circuit_state(&s.base_url),
                "success_count": quality_full.map(|q| q.0).unwrap_or(0),
                "sanity_fail_count": quality_full.map(|q| q.1).unwrap_or(0),
                "latency_ms_p50": quality_full.and_then(|q| q.2),
                "latency_ms_p95": quality_full.and_then(|q| q.3),
                "tool_call_accuracy": quality_full.and_then(|q| q.4),
            })
        })
        .collect();
    let provider_summary = crate::cost_tracker::provider_daily_summary();
    Ok(Json(serde_json::json!({
        "slots": slots,
        "enabled": true,
        "provider_summary": provider_summary,
        "total_remaining_rpd": total_remaining_rpd
    })))
}

/// POST /api/cascade-slot-toggle — enable or disable a cascade slot, persisted to config.toml.
/// Body: {"slot": "<name>", "enabled": true|false}
pub async fn handle_cascade_slot_toggle(
    axum::extract::Json(body): axum::extract::Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let slot = body
        .get("slot")
        .and_then(|v| v.as_str())
        .ok_or(StatusCode::BAD_REQUEST)?
        .to_string();
    let enabled = body
        .get("enabled")
        .and_then(|v| v.as_bool())
        .ok_or(StatusCode::BAD_REQUEST)?;

    let mut disabled = read_cascade_disabled();
    if enabled {
        disabled.retain(|s| s != &slot);
    } else if !disabled.contains(&slot) {
        disabled.push(slot.clone());
    }

    write_cascade_disabled(&disabled).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    tracing::info!(
        slot = %slot,
        enabled = enabled,
        disabled_count = disabled.len(),
        "cascade_slot_toggle: slot {} → {} (config.toml updated)",
        slot,
        if enabled { "enabled" } else { "disabled" }
    );

    Ok(Json(serde_json::json!({
        "slot": slot,
        "enabled": enabled,
        "disabled_slots": disabled,
    })))
}

/// GET /api/causal-timeline — chronological action nodes for causal retrospection (Zone D).
/// Returns recent tool predictions with outcomes, surprise values, and regime context.
pub async fn handle_causal_timeline(
    axum::extract::Query(params): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let limit = params
        .get("limit")
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(50)
        .min(100);

    let _limit = limit;
    Ok(Json(serde_json::json!({
        "nodes": [],
        "per_tool_summary": [],
        "total_returned": 0,
    })))
}

/// GET /api/cognitive-state — full cognitive substrate snapshot for the telemetry UI.
pub async fn handle_cognitive_state() -> Json<serde_json::Value> {
    let surprise_ema = 0.0_f64;
    let surprise_total = 0_u64;
    let surprise_high = 0_u64;
    let surprise_pct = 0.0_f64;

    let task = crate::belief_state::task_belief();
    let belief_metrics = crate::belief_state::metrics_json();

    let nm = crate::neuromodulation::metrics_json();

    let regime = crate::precision_controller::current_regime();
    let tier = crate::precision_controller::recommended_model_tier();
    let params = crate::precision_controller::adaptive_params();

    let phi = crate::phi_proxy::metrics_json();

    let bb = crate::blackboard::global();
    let bb_count = bb.entry_count();
    let bb_recent: Vec<serde_json::Value> = bb
        .broadcast_entries()
        .into_iter()
        .take(8)
        .map(|e| {
            serde_json::json!({
                "id": e.id,
                "source": format!("{:?}", e.source),
                "content": if e.content.len() > 200 {
                    format!("{}…", &e.content[..200])
                } else {
                    e.content.clone()
                },
                "salience": (e.salience * 1000.0).round() / 1000.0,
            })
        })
        .collect();

    let surprise_history: Vec<f64> = vec![];

    Json(serde_json::json!({
        "surprise": {
            "ema": (surprise_ema * 10000.0).round() / 10000.0,
            "total_predictions": surprise_total,
            "high_surprise_count": surprise_high,
            "high_surprise_pct": (surprise_pct * 10.0).round() / 10.0,
            "history": surprise_history,
        },
        "belief_state": belief_metrics,
        "neuromodulation": nm,
        "precision": {
            "regime": regime.to_string(),
            "model_tier": tier.to_string(),
            "exploration_epsilon": params.regime.to_string(),
            "max_tool_calls": params.max_tool_calls,
            "context_exploration_fraction": (params.context_exploration_fraction * 1000.0).round() / 1000.0,
            "budget_critical": params.budget_critical,
            "token_budget_remaining": (crate::precision_controller::token_budget_remaining() * 1000.0).round() / 1000.0,
            "escalation_rate": (crate::precision_controller::escalation_rate() * 1000.0).round() / 1000.0,
            "context_scale": {
                "mode": crate::env_flags::context_scale_status().0,
                "currently_slim": crate::env_flags::context_scale_status().1,
            },
        },
        "blackboard": {
            "entry_count": bb_count,
            "recent_entries": bb_recent,
        },
        "phi_proxy": phi,
        "task": {
            "trajectory_confidence": (task.trajectory_confidence * 1000.0).round() / 1000.0,
            "model_freshness": (task.model_freshness * 1000.0).round() / 1000.0,
            "uncertainty": (task.uncertainty() * 1000.0).round() / 1000.0,
            "streak_successes": task.streak_successes,
            "streak_failures": task.streak_failures,
        },
    }))
}

/// GET /api/neuromod-stream — SSE stream of neuromodulation state at 1Hz.
/// Lightweight alternative to polling /api/cognitive-state for real-time HUD updates.
pub async fn handle_neuromod_stream(
) -> Sse<impl tokio_stream::Stream<Item = Result<Event, std::convert::Infallible>>> {
    let (tx, rx) =
        tokio::sync::mpsc::unbounded_channel::<Result<Event, std::convert::Infallible>>();
    tokio::spawn(async move {
        loop {
            let nm = crate::neuromodulation::metrics_json();
            let regime = crate::precision_controller::current_regime().to_string();
            let payload = serde_json::json!({
                "neuromodulation": nm,
                "regime": regime,
                "surprise_ema": 0.0,
            });
            if tx
                .send(Ok(Event::default().data(payload.to_string())))
                .is_err()
            {
                break; // Client disconnected
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    });
    Sse::new(tokio_stream::wrappers::UnboundedReceiverStream::new(rx)).keep_alive(
        axum::response::sse::KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("ping"),
    )
}

// ── INFRA-1339: /api/fleet/pillars — 4-pillar mission grade JSON ──
//
// Powers PRODUCT-107 status-footer pillar quadrant + INFRA-1203 health view
// pillar grades. Reuses crate::mission_grade::build_report (the same call
// `chump mission-grade` makes) and serializes per-pillar
// {grade, score, count_pickable, count_in_flight, count_shipped_24h, trend,
// breach_reasons}. Trend is currently always "flat" — wiring up history is
// a follow-up (file when we want sparklines).
//
// Cache: 60s in-process via OnceLock<Mutex<Option<Snapshot>>>. Pillar grades
// don't move minute-to-minute, and computing the report touches sqlite +
// disk, so caching protects against PWA-poll storms.

#[derive(Clone)]
struct PillarsSnapshot {
    payload: serde_json::Value,
    cached_at: Instant,
}

fn pillars_cache() -> &'static OnceLock<Mutex<Option<PillarsSnapshot>>> {
    static CELL: OnceLock<Mutex<Option<PillarsSnapshot>>> = OnceLock::new();
    &CELL
}

/// GET /api/fleet/pillars — see module doc for schema.
pub async fn handle_fleet_pillars() -> Json<serde_json::Value> {
    let ttl = Duration::from_secs(60);
    let cell = pillars_cache().get_or_init(|| Mutex::new(None));

    if let Ok(g) = cell.lock() {
        if let Some(snap) = g.as_ref() {
            if snap.cached_at.elapsed() < ttl {
                return Json(snap.payload.clone());
            }
        }
    }

    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => std::path::PathBuf::from(r),
        Err(_) => crate::repo_path::runtime_base(),
    };
    let report = crate::mission_grade::build_report(&repo_root);
    let payload = pillars_report_to_json(&report);

    let mission_grade = payload
        .get("mission")
        .and_then(|m| m.get("grade"))
        .and_then(|g| g.as_str())
        .unwrap_or("?");
    tracing::info!(
        target: "chump::fleet_pillars",
        mission_grade,
        effective_grade = payload
            .get("effective")
            .and_then(|m| m.get("grade"))
            .and_then(|g| g.as_str())
            .unwrap_or("?"),
        "fleet pillars computed (cache miss)"
    );

    if let Ok(mut g) = cell.lock() {
        *g = Some(PillarsSnapshot {
            payload: payload.clone(),
            cached_at: Instant::now(),
        });
    }
    Json(payload)
}

fn pillar_entry(c: &crate::mission_grade::PillarCounts) -> serde_json::Value {
    let grade_ch = crate::mission_grade::pillar_grade(c.count_pickable, c.count_in_flight);
    // Score: rough 0-100 indicator. 25 per pickable, 10 per in-flight, 5 per shipped/24h, clamp to 100.
    let raw: u64 = c
        .count_pickable
        .saturating_mul(25)
        .saturating_add(c.count_in_flight.saturating_mul(10))
        .saturating_add(c.count_shipped_24h.saturating_mul(5));
    let score = raw.min(100);

    let mut reasons: Vec<String> = Vec::new();
    if grade_ch == 'F' {
        reasons.push("no open gaps tagged for this pillar".to_string());
    } else if grade_ch == 'C' {
        reasons.push(format!("0 pickable; {} in flight", c.count_in_flight));
    } else if grade_ch == 'B' {
        reasons.push("only 1 pickable gap — restock to >=2".to_string());
    }

    serde_json::json!({
        "grade": grade_ch.to_string(),
        "score": score,
        "count_pickable": c.count_pickable,
        "count_in_flight": c.count_in_flight,
        "count_shipped_24h": c.count_shipped_24h,
        "trend": "flat",
        "breach_reasons": reasons,
    })
}

fn pillars_report_to_json(r: &crate::mission_grade::MissionGradeReport) -> serde_json::Value {
    // Aggregate mission grade: worst of the 4 (A>B>C>F).
    let grades = [
        crate::mission_grade::pillar_grade(r.effective.count_pickable, r.effective.count_in_flight),
        crate::mission_grade::pillar_grade(r.credible.count_pickable, r.credible.count_in_flight),
        crate::mission_grade::pillar_grade(r.resilient.count_pickable, r.resilient.count_in_flight),
        crate::mission_grade::pillar_grade(
            r.zero_waste.count_pickable,
            r.zero_waste.count_in_flight,
        ),
    ];
    let mission_grade = grades
        .iter()
        .max_by_key(|g| grade_severity(**g))
        .unwrap_or(&'F');
    let mission_score = {
        let mut total = 0u64;
        for c in [&r.effective, &r.credible, &r.resilient, &r.zero_waste] {
            let raw: u64 = c
                .count_pickable
                .saturating_mul(25)
                .saturating_add(c.count_in_flight.saturating_mul(10))
                .saturating_add(c.count_shipped_24h.saturating_mul(5));
            total = total.saturating_add(raw.min(100));
        }
        total / 4
    };
    let mut mission_breach: Vec<String> = Vec::new();
    for (counts, name) in [
        (&r.effective, "effective"),
        (&r.credible, "credible"),
        (&r.resilient, "resilient"),
        (&r.zero_waste, "zero_waste"),
    ] {
        if counts.count_pickable < 2 {
            mission_breach.push(format!(
                "{} has {} pickable (target >=2)",
                name, counts.count_pickable
            ));
        }
    }
    serde_json::json!({
        "ts": r.ts,
        "effective": pillar_entry(&r.effective),
        "credible": pillar_entry(&r.credible),
        "resilient": pillar_entry(&r.resilient),
        "zero_waste": pillar_entry(&r.zero_waste),
        "mission": {
            "grade": mission_grade.to_string(),
            "score": mission_score,
            "breach_reasons": mission_breach,
            "trend": "flat",
        },
    })
}

fn grade_severity(g: char) -> u8 {
    match g {
        'A' => 0,
        'B' => 1,
        'C' => 2,
        'F' => 3,
        _ => 4,
    }
}

#[cfg(test)]
mod fleet_pillars_tests {
    use super::*;
    use crate::mission_grade::{MissionGradeReport, PillarCounts};

    #[test]
    fn pillar_entry_grade_a_two_pickable() {
        let c = PillarCounts {
            count_pickable: 3,
            count_in_flight: 1,
            count_shipped_24h: 2,
        };
        let v = pillar_entry(&c);
        assert_eq!(v["grade"], "A");
        assert_eq!(v["count_pickable"], 3);
        assert_eq!(v["count_in_flight"], 1);
        assert_eq!(v["count_shipped_24h"], 2);
        assert_eq!(v["trend"], "flat");
        assert!(v["breach_reasons"].as_array().unwrap().is_empty());
    }

    #[test]
    fn pillar_entry_grade_b_one_pickable_has_restock_reason() {
        let c = PillarCounts {
            count_pickable: 1,
            count_in_flight: 0,
            count_shipped_24h: 0,
        };
        let v = pillar_entry(&c);
        assert_eq!(v["grade"], "B");
        let reasons = v["breach_reasons"].as_array().unwrap();
        assert_eq!(reasons.len(), 1);
        assert!(reasons[0].as_str().unwrap().contains("only 1 pickable"));
    }

    #[test]
    fn pillar_entry_grade_f_no_open_has_reason() {
        let c = PillarCounts::default();
        let v = pillar_entry(&c);
        assert_eq!(v["grade"], "F");
        let reasons = v["breach_reasons"].as_array().unwrap();
        assert_eq!(reasons.len(), 1);
    }

    #[test]
    fn report_to_json_full_shape() {
        let r = MissionGradeReport {
            effective: PillarCounts {
                count_pickable: 3,
                count_in_flight: 0,
                count_shipped_24h: 0,
            },
            credible: PillarCounts {
                count_pickable: 1,
                count_in_flight: 0,
                count_shipped_24h: 0,
            },
            resilient: PillarCounts {
                count_pickable: 0,
                count_in_flight: 2,
                count_shipped_24h: 0,
            },
            zero_waste: PillarCounts::default(),
            ts: "2026-05-15T20:30:00Z".to_string(), // chump-fmt: time-bomb-ok
        };
        let v = pillars_report_to_json(&r);
        assert_eq!(v["effective"]["grade"], "A");
        assert_eq!(v["credible"]["grade"], "B");
        assert_eq!(v["resilient"]["grade"], "C");
        assert_eq!(v["zero_waste"]["grade"], "F");
        // Mission grade is worst of the 4.
        assert_eq!(v["mission"]["grade"], "F");
        assert_eq!(v["ts"], "2026-05-15T20:30:00Z"); // chump-fmt: time-bomb-ok
        let mission_reasons = v["mission"]["breach_reasons"].as_array().unwrap();
        // zero_waste + resilient + credible all have <2 pickable.
        assert!(mission_reasons.len() >= 3);
    }
}
