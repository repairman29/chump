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

    // INFRA-1337: merge the github_rate_limit snapshot into the top-level object.
    let mut body = serde_json::json!({
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
    });
    // Merge the two rate-limit keys (github_rate_limit + github_rate_limit_error)
    // directly into the top-level object so callers can do d.github_rate_limit.
    if let (Some(obj), serde_json::Value::Object(rl_map)) = (
        body.as_object_mut(),
        crate::github_rate_limit::snapshot_json(),
    ) {
        obj.extend(rl_map);
    }
    Json(body)
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

/// GET /api/slots — per-slot inference performance metrics for the PWA settings page (PRODUCT-055).
///
/// Returns an array of slot objects. Each slot includes aggregated quality data from
/// `chump_provider_quality` (latency p50/p95, success/fail counts, last_updated) plus
/// the last-10 request history from `chump_slot_request_history` (for sparklines).
///
/// Callers should poll every 5 seconds; this endpoint is read-only and cheap.
pub async fn handle_slots() -> Result<Json<serde_json::Value>, StatusCode> {
    if let Some(arc) = crate::provider_cascade::cascade_for_status() {
        return Ok(Json(build_slots_response(&arc.slots)));
    }
    let c = crate::provider_cascade::ProviderCascade::from_env();
    if c.slots.is_empty() {
        return Ok(Json(serde_json::json!({ "slots": [] })));
    }
    Ok(Json(build_slots_response(&c.slots)))
}

fn build_slots_response(slots: &[crate::provider_cascade::ProviderSlot]) -> serde_json::Value {
    let slot_data: Vec<serde_json::Value> = slots
        .iter()
        .map(|s| {
            let quality = crate::provider_quality::get_quality_full(&s.name);
            let history = crate::provider_quality::get_request_history(&s.name);
            // Compute tokens/sec from history: average(tokens_out / (latency_ms / 1000)).
            // Skip entries where tokens_out == 0 (unknown) or latency == 0.
            let tps_samples: Vec<f64> = history
                .iter()
                .filter(|e| e.tokens_out > 0 && e.latency_ms > 0.0)
                .map(|e| e.tokens_out as f64 / (e.latency_ms / 1000.0))
                .collect();
            let avg_tokens_per_sec: Option<f64> = if tps_samples.is_empty() {
                None
            } else {
                Some(tps_samples.iter().sum::<f64>() / tps_samples.len() as f64)
            };
            // last_used_at: take the most recent request history timestamp if available.
            let last_used_at: Option<String> = history.first().map(|e| e.recorded_at.clone());
            // Serialize history entries for sparkline rendering.
            let request_history: Vec<serde_json::Value> = history
                .iter()
                .map(|e| {
                    serde_json::json!({
                        "ts": e.recorded_at,
                        "latency_ms": e.latency_ms,
                        "tokens_out": e.tokens_out,
                    })
                })
                .collect();
            serde_json::json!({
                "name": s.name,
                "latency_ms_p50": quality.and_then(|q| q.2),
                "latency_ms_p95": quality.and_then(|q| q.3),
                "avg_tokens_per_sec": avg_tokens_per_sec,
                "success_count": quality.map(|q| q.0).unwrap_or(0),
                "sanity_fail_count": quality.map(|q| q.1).unwrap_or(0),
                "last_used_at": last_used_at,
                "request_history": request_history,
            })
        })
        .collect();
    serde_json::json!({ "slots": slot_data })
}
// ── INFRA-1334: /api/fleet/health — aggregate mission health snapshot ──────
//
// Returns a single JSON object combining pillar grades, KPIs, SLO status, and
// GraphQL budget. Designed to be the single data source for:
//   - PRODUCT-107 status-footer pillar quadrant
//   - INFRA-1203 <chump-view-fleet-health> detail view
//
// Shape:
//   {
//     pillars: { effective:{grade,score,count_pickable,...}, credible:...,
//                resilient:..., zero_waste:..., mission:... },
//     kpis: { ships_24h, open_count, claimed_count, waste_rate_pct },
//     slo:  { status:"ok"|"breach"|"unknown", breach_count, breaches:[] },
//     graphql_budget: { remaining, limit, reset_at } | null,
//     ts: ISO string,
//   }
//
// Cache: 60s in-process OnceLock. Protects against PWA poll storms.

#[derive(Clone)]
struct FleetHealthSnapshot {
    payload: serde_json::Value,
    cached_at: Instant,
}

fn fleet_health_cache() -> &'static OnceLock<Mutex<Option<FleetHealthSnapshot>>> {
    static CELL: OnceLock<Mutex<Option<FleetHealthSnapshot>>> = OnceLock::new();
    &CELL
}

/// GET /api/fleet/health — see module doc for full schema.
pub async fn handle_fleet_health() -> Json<serde_json::Value> {
    let ttl = Duration::from_secs(60);
    let cell = fleet_health_cache().get_or_init(|| Mutex::new(None));

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
    let pillars = fleet_health_pillars_json(&report);
    let kpis = fleet_health_kpis_json(&repo_root, &report);
    let slo = fleet_health_slo_json(&repo_root);
    let graphql_budget = fleet_health_graphql_budget_json(&repo_root);
    let ts = report.ts.clone();

    let mission_grade = pillars
        .get("mission")
        .and_then(|m| m.get("grade"))
        .and_then(|g| g.as_str())
        .unwrap_or("?")
        .to_string();
    let slo_status = slo
        .get("status")
        .and_then(|s| s.as_str())
        .unwrap_or("unknown")
        .to_string();
    let graphql_remaining = graphql_budget
        .get("remaining")
        .and_then(|r| r.as_i64())
        .unwrap_or(-1);

    tracing::info!(
        target: "chump::fleet_health",
        mission_grade,
        slo_status,
        graphql_remaining,
        "fleet health computed (cache miss)"
    );

    let payload = serde_json::json!({
        "pillars": pillars,
        "kpis": kpis,
        "slo": slo,
        "graphql_budget": graphql_budget,
        "ts": ts,
    });

    if let Ok(mut g) = cell.lock() {
        *g = Some(FleetHealthSnapshot {
            payload: payload.clone(),
            cached_at: Instant::now(),
        });
    }
    Json(payload)
}

// ── Pillar sub-object — mirrors /api/fleet/pillars (INFRA-1339) ────────────

fn pillar_entry_health(c: &crate::mission_grade::PillarCounts) -> serde_json::Value {
    let grade_ch = crate::mission_grade::pillar_grade(c.count_pickable, c.count_in_flight);
    let raw: u64 = c
        .count_pickable
        .saturating_mul(25)
        .saturating_add(c.count_in_flight.saturating_mul(10))
        .saturating_add(c.count_shipped_24h.saturating_mul(5));
    let score = raw.min(100);

    let mut breach_reasons: Vec<&str> = vec![];
    match grade_ch {
        'A' => {}
        'B' => breach_reasons.push("only 1 pickable gap — restock to 2+"),
        'C' => breach_reasons.push("no pickable gaps (all in-flight or blocked)"),
        _ => breach_reasons.push("no open gaps in this pillar"),
    }

    serde_json::json!({
        "grade": grade_ch.to_string(),
        "score": score,
        "count_pickable": c.count_pickable,
        "count_in_flight": c.count_in_flight,
        "count_shipped_24h": c.count_shipped_24h,
        "trend": "flat",
        "breach_reasons": breach_reasons,
    })
}

fn fleet_health_pillars_json(r: &crate::mission_grade::MissionGradeReport) -> serde_json::Value {
    let eff = pillar_entry_health(&r.effective);
    let cred = pillar_entry_health(&r.credible);
    let res = pillar_entry_health(&r.resilient);
    let zw = pillar_entry_health(&r.zero_waste);

    // Mission: worst grade across pillars; score = min; breach_reasons = union
    let grades = [
        eff["grade"].as_str().unwrap_or("F"),
        cred["grade"].as_str().unwrap_or("F"),
        res["grade"].as_str().unwrap_or("F"),
        zw["grade"].as_str().unwrap_or("F"),
    ];
    let grade_rank = |g: &str| match g {
        "A" => 4u8,
        "B" => 3,
        "C" => 2,
        _ => 1,
    };
    let mission_grade = grades
        .iter()
        .min_by_key(|g| grade_rank(g))
        .copied()
        .unwrap_or("F");
    let mission_score = [
        eff["score"].as_u64().unwrap_or(0),
        cred["score"].as_u64().unwrap_or(0),
        res["score"].as_u64().unwrap_or(0),
        zw["score"].as_u64().unwrap_or(0),
    ]
    .iter()
    .copied()
    .min()
    .unwrap_or(0);

    let mut mission_reasons: Vec<&str> = vec![];
    for v in [&eff, &cred, &res, &zw] {
        if let Some(arr) = v["breach_reasons"].as_array() {
            for r in arr {
                if let Some(s) = r.as_str() {
                    mission_reasons.push(s);
                }
            }
        }
    }

    serde_json::json!({
        "effective": eff,
        "credible": cred,
        "resilient": res,
        "zero_waste": zw,
        "mission": {
            "grade": mission_grade,
            "score": mission_score,
            "trend": "flat",
            "breach_reasons": mission_reasons,
        },
    })
}

// ── KPIs sub-object ────────────────────────────────────────────────────────

fn fleet_health_kpis_json(
    repo_root: &std::path::Path,
    report: &crate::mission_grade::MissionGradeReport,
) -> serde_json::Value {
    let gs = match crate::gap_store::GapStore::open(repo_root) {
        Ok(g) => g,
        Err(_) => {
            return serde_json::json!({
                "ships_24h": 0,
                "open_count": 0,
                "claimed_count": 0,
                "waste_rate_pct": 0.0,
            })
        }
    };

    let open_count = gs.list(Some("open")).map(|v| v.len()).unwrap_or(0) as u64;
    let claimed_count = gs.list(Some("claimed")).map(|v| v.len()).unwrap_or(0) as u64;

    // ships_24h: sum of shipped_24h across all 4 pillars (which already counted from done list)
    let ships_24h = report.effective.count_shipped_24h
        + report.credible.count_shipped_24h
        + report.resilient.count_shipped_24h
        + report.zero_waste.count_shipped_24h;

    // waste_rate_pct: (open_count / (open_count + ships_24h_over_week)) rough proxy.
    // Simplified: use 0.0 when we have no shipping history (can't compute meaningful rate
    // from in-memory data alone — the proper source is chump waste-tally which needs disk scan).
    let waste_rate_pct: f64 = 0.0;

    serde_json::json!({
        "ships_24h": ships_24h,
        "open_count": open_count,
        "claimed_count": claimed_count,
        "waste_rate_pct": waste_rate_pct,
    })
}

// ── SLO sub-object ─────────────────────────────────────────────────────────

fn fleet_health_slo_json(_repo_root: &std::path::Path) -> serde_json::Value {
    // Try `chump health --slo-check --json`. If the binary is unavailable or the flag
    // is unrecognised, fall back to status:unknown.
    let chump_bin = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("chump"));
    let result = std::process::Command::new(&chump_bin)
        .args(["health", "--slo-check", "--json"])
        .env("CHUMP_ALLOW_MAIN_WORKTREE", "1")
        .output();

    match result {
        Ok(out) if out.status.success() => {
            if let Ok(s) = std::str::from_utf8(&out.stdout) {
                if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(s.trim()) {
                    return parsed;
                }
            }
            serde_json::json!({ "status": "unknown", "breach_count": 0, "breaches": [] })
        }
        Ok(out) if out.status.code() == Some(1) => {
            // exit 1 means SLO breach
            if let Ok(s) = std::str::from_utf8(&out.stdout) {
                if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(s.trim()) {
                    return parsed;
                }
            }
            serde_json::json!({ "status": "breach", "breach_count": 1, "breaches": [] })
        }
        _ => serde_json::json!({ "status": "unknown", "breach_count": 0, "breaches": [] }),
    }
}

// ── GraphQL budget sub-object ───────────────────────────────────────────────

fn fleet_health_graphql_budget_json(repo_root: &std::path::Path) -> serde_json::Value {
    // Read the most recent graphql_exhausted or graphql_rate event from ambient.jsonl.
    // This avoids an external gh api call on every request.
    // Returns null when no signal is available.
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let content = match std::fs::read_to_string(&ambient_path) {
        Ok(c) => c,
        Err(_) => return serde_json::Value::Null,
    };

    // Scan in reverse for the most recent graphql_exhausted event.
    for line in content.lines().rev() {
        if !line.contains("graphql_exhausted") && !line.contains("graphql_remaining") {
            continue;
        }
        if let Ok(ev) = serde_json::from_str::<serde_json::Value>(line) {
            let remaining = ev.get("threshold_seen").and_then(|v| v.as_i64());
            let reset_at = ev.get("resets_at").and_then(|v| v.as_str()).map(|s| {
                if s == "unknown" {
                    serde_json::Value::Null
                } else {
                    serde_json::Value::String(s.to_string())
                }
            });
            if remaining.is_some() || reset_at.is_some() {
                return serde_json::json!({
                    "remaining": remaining,
                    "limit": 5000,
                    "reset_at": reset_at.unwrap_or(serde_json::Value::Null),
                });
            }
        }
    }

    // No graphql event found — return null so callers know this data is unavailable.
    serde_json::Value::Null
}

#[cfg(test)]
mod fleet_health_tests {
    use super::*;
    use crate::mission_grade::{MissionGradeReport, PillarCounts};

    #[test]
    fn pillar_entry_grade_a() {
        let c = PillarCounts {
            count_pickable: 2,
            count_in_flight: 1,
            count_shipped_24h: 3,
        };
        let v = pillar_entry_health(&c);
        assert_eq!(v["grade"], "A");
        assert!(v["breach_reasons"].as_array().unwrap().is_empty());
    }

    #[test]
    fn pillar_entry_grade_f_has_breach_reason() {
        let c = PillarCounts::default();
        let v = pillar_entry_health(&c);
        assert_eq!(v["grade"], "F");
        assert_eq!(v["breach_reasons"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn fleet_health_pillars_mission_worst_grade() {
        let r = MissionGradeReport {
            effective: PillarCounts {
                count_pickable: 3,
                count_in_flight: 0,
                count_shipped_24h: 0,
            },
            credible: PillarCounts::default(), // F
            resilient: PillarCounts {
                count_pickable: 1,
                count_in_flight: 0,
                count_shipped_24h: 0,
            }, // B
            zero_waste: PillarCounts {
                count_pickable: 2,
                count_in_flight: 0,
                count_shipped_24h: 0,
            }, // A
            ts: "".to_string(),
        };
        let v = fleet_health_pillars_json(&r);
        assert_eq!(v["effective"]["grade"], "A");
        assert_eq!(v["credible"]["grade"], "F");
        assert_eq!(v["resilient"]["grade"], "B");
        assert_eq!(v["zero_waste"]["grade"], "A");
        // Mission = worst = F
        assert_eq!(v["mission"]["grade"], "F");
    }

    #[test]
    fn graphql_budget_null_on_missing_ambient() {
        let tmp = std::path::PathBuf::from("/tmp/no-such-repo-infra-1334-test");
        let v = fleet_health_graphql_budget_json(&tmp);
        assert!(v.is_null());
    }
}
