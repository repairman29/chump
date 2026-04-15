//! Health, stack-status, cascade-status, cognitive-state, and favicon handlers.

use axum::http::StatusCode;
use axum::response::sse::{Event, Sse};
use axum::{response::Redirect, Json};
use std::time::Duration;

use crate::local_openai;
use crate::provider_cascade;

pub async fn handle_health() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "ok",
        "service": "chump-web"
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

/// GET /api/cascade-status
pub async fn handle_cascade_status() -> Result<Json<serde_json::Value>, StatusCode> {
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

    let predictions = crate::surprise_tracker::recent_predictions(None, limit)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let nodes: Vec<serde_json::Value> = predictions
        .iter()
        .map(|p| {
            serde_json::json!({
                "id": p.id,
                "tool": p.tool,
                "outcome": p.outcome,
                "latency_ms": p.latency_ms,
                "surprisal": (p.surprisal * 10000.0).round() / 10000.0,
                "recorded_at": p.recorded_at,
            })
        })
        .collect();

    let per_tool = crate::surprise_tracker::mean_surprisal_by_tool(limit)
        .unwrap_or_default()
        .into_iter()
        .map(|(tool, avg, count)| {
            serde_json::json!({
                "tool": tool,
                "mean_surprisal": (avg * 10000.0).round() / 10000.0,
                "count": count,
            })
        })
        .collect::<Vec<_>>();

    Ok(Json(serde_json::json!({
        "nodes": nodes,
        "per_tool_summary": per_tool,
        "total_returned": nodes.len(),
    })))
}

/// GET /api/cognitive-state — full cognitive substrate snapshot for the telemetry UI.
pub async fn handle_cognitive_state() -> Json<serde_json::Value> {
    let surprise_ema = crate::surprise_tracker::current_surprisal_ema();
    let surprise_total = crate::surprise_tracker::total_predictions();
    let surprise_high = crate::surprise_tracker::high_surprise_count();
    let surprise_pct = crate::surprise_tracker::high_surprise_pct();

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

    // Recent surprisal values for sparkline (last 30 predictions, chronological)
    let surprise_history: Vec<f64> = crate::surprise_tracker::recent_predictions(None, 30)
        .unwrap_or_default()
        .into_iter()
        .rev()
        .map(|p| (p.surprisal * 10000.0).round() / 10000.0)
        .collect();

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
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel::<Result<Event, std::convert::Infallible>>();
    tokio::spawn(async move {
        loop {
            let nm = crate::neuromodulation::metrics_json();
            let regime = crate::precision_controller::current_regime().to_string();
            let surprise_ema = crate::surprise_tracker::current_surprisal_ema();
            let payload = serde_json::json!({
                "neuromodulation": nm,
                "regime": regime,
                "surprise_ema": (surprise_ema * 10000.0).round() / 10000.0,
            });
            if tx.send(Ok(Event::default().data(payload.to_string()))).is_err() {
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
