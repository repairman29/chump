//! Health, stack-status, cascade-status, cognitive-state, and favicon handlers.

use axum::http::StatusCode;
use axum::response::sse::{Event, Sse};
use axum::{response::Redirect, Json};
use std::sync::{OnceLock, RwLock};
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

// ── INFRA-1341: /api/acp/health — detect installed ACP client handlers ──
//
// PRODUCT-110 deeplinks (`chump://acp/open?...`) need to know whether *any*
// handler is registered before surfacing the link — otherwise we send the
// operator into a dead URL. This endpoint enumerates known ACP-capable
// editors (Zed, JetBrains IDEA family) by probing PATH + well-known install
// paths, caches for 60s, and returns 200 even when no handler is present
// so the frontend can render a "no handler registered" tooltip without
// dealing with a 5xx.

#[derive(Clone)]
struct AcpHealthSnapshot {
    payload: serde_json::Value,
    cached_at: Instant,
}

fn acp_health_cache() -> &'static OnceLock<RwLock<Option<AcpHealthSnapshot>>> {
    static CELL: OnceLock<RwLock<Option<AcpHealthSnapshot>>> = OnceLock::new();
    &CELL
}

/// GET /api/acp/health — see module doc for schema.
pub async fn handle_acp_health() -> Json<serde_json::Value> {
    let ttl = Duration::from_secs(60);
    let cell = acp_health_cache().get_or_init(|| RwLock::new(None));
    if let Ok(g) = cell.read() {
        if let Some(snap) = g.as_ref() {
            if snap.cached_at.elapsed() < ttl {
                return Json(snap.payload.clone());
            }
        }
    }
    let payload = build_acp_health_payload();
    if let Ok(mut g) = cell.write() {
        *g = Some(AcpHealthSnapshot {
            payload: payload.clone(),
            cached_at: Instant::now(),
        });
    }
    Json(payload)
}

fn build_acp_health_payload() -> serde_json::Value {
    let generated_at = {
        use chrono::Utc;
        Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
    };

    let zed = detect_zed();
    let jetbrains = detect_jetbrains();
    let any_present = zed["present"].as_bool().unwrap_or(false)
        || jetbrains["present"].as_bool().unwrap_or(false);

    serde_json::json!({
        "clients": [zed, jetbrains],
        "any_handler_present": any_present,
        "generated_at_iso": generated_at,
        "acp_error": serde_json::Value::Null,
    })
}

fn home_dir() -> std::path::PathBuf {
    std::env::var("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("/"))
}

fn which_bin(name: &str) -> Option<String> {
    // Allow test override via CHUMP_ACP_PATH so CI can stub PATH without
    // mutating the runner's real environment.
    let path = std::env::var("CHUMP_ACP_PATH")
        .ok()
        .or_else(|| std::env::var("PATH").ok())
        .unwrap_or_default();
    for dir in path.split(':') {
        if dir.is_empty() {
            continue;
        }
        let candidate = std::path::Path::new(dir).join(name);
        if candidate.is_file() {
            // Best-effort executable check: any file in PATH/<name> counts.
            return Some(candidate.display().to_string());
        }
    }
    None
}

fn detect_zed() -> serde_json::Value {
    // Override for tests: CHUMP_ACP_ZED_OVERRIDE=present|absent
    if let Ok(v) = std::env::var("CHUMP_ACP_ZED_OVERRIDE") {
        let present = v == "present";
        let detected_at: serde_json::Value = if present {
            serde_json::Value::String("stub".to_string())
        } else {
            serde_json::Value::Null
        };
        let binary_path: serde_json::Value = if present {
            serde_json::Value::String("/stub/zed".to_string())
        } else {
            serde_json::Value::Null
        };
        return serde_json::json!({
            "id": "zed",
            "name": "Zed",
            "present": present,
            "detected_at": detected_at,
            "version": serde_json::Value::Null,
            "binary_path": binary_path,
        });
    }
    let binary_path = which_bin("zed");
    let home = home_dir();
    // macOS app-support path.
    let mac_support = home.join("Library/Application Support/Zed");
    let mac_support_present = mac_support.is_dir();
    // Linux/BSD config path.
    let xdg_support = home.join(".config/zed");
    let xdg_support_present = xdg_support.is_dir();

    let present = binary_path.is_some() || mac_support_present || xdg_support_present;
    let detected_at = if binary_path.is_some() {
        "PATH"
    } else if mac_support_present {
        "Library/Application Support/Zed"
    } else if xdg_support_present {
        ".config/zed"
    } else {
        ""
    };
    serde_json::json!({
        "id": "zed",
        "name": "Zed",
        "present": present,
        "detected_at": if detected_at.is_empty() { serde_json::Value::Null } else { serde_json::Value::String(detected_at.to_string()) },
        "version": serde_json::Value::Null,
        "binary_path": binary_path,
    })
}

fn detect_jetbrains() -> serde_json::Value {
    if let Ok(v) = std::env::var("CHUMP_ACP_JETBRAINS_OVERRIDE") {
        let present = v == "present";
        let detected_at: serde_json::Value = if present {
            serde_json::Value::String("stub".to_string())
        } else {
            serde_json::Value::Null
        };
        let binary_path: serde_json::Value = if present {
            serde_json::Value::String("/stub/idea".to_string())
        } else {
            serde_json::Value::Null
        };
        return serde_json::json!({
            "id": "jetbrains",
            "name": "JetBrains IDEA family",
            "present": present,
            "detected_at": detected_at,
            "version": serde_json::Value::Null,
            "binary_path": binary_path,
        });
    }
    // Common JetBrains launchers.
    let launchers = [
        "idea", "pycharm", "webstorm", "rubymine", "rider", "clion", "goland", "phpstorm",
    ];
    let mut binary_path: Option<String> = None;
    let mut detected_launcher: Option<&str> = None;
    for l in launchers.iter() {
        if let Some(p) = which_bin(l) {
            binary_path = Some(p);
            detected_launcher = Some(l);
            break;
        }
    }
    let home = home_dir();
    let mac_support = home.join("Library/Application Support/JetBrains");
    let mac_support_present = mac_support.is_dir();
    let linux_support = home.join(".config/JetBrains");
    let linux_support_present = linux_support.is_dir();

    let present = binary_path.is_some() || mac_support_present || linux_support_present;
    let detected_at = if let Some(l) = detected_launcher {
        format!("PATH ({})", l)
    } else if mac_support_present {
        "Library/Application Support/JetBrains".to_string()
    } else if linux_support_present {
        ".config/JetBrains".to_string()
    } else {
        String::new()
    };
    serde_json::json!({
        "id": "jetbrains",
        "name": "JetBrains IDEA family",
        "present": present,
        "detected_at": if detected_at.is_empty() { serde_json::Value::Null } else { serde_json::Value::String(detected_at) },
        "version": serde_json::Value::Null,
        "binary_path": binary_path,
    })
}

#[cfg(test)]
mod acp_health_tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn override_absent_marks_no_handler() {
        std::env::set_var("CHUMP_ACP_ZED_OVERRIDE", "absent");
        std::env::set_var("CHUMP_ACP_JETBRAINS_OVERRIDE", "absent");
        let p = build_acp_health_payload();
        std::env::remove_var("CHUMP_ACP_ZED_OVERRIDE");
        std::env::remove_var("CHUMP_ACP_JETBRAINS_OVERRIDE");
        assert_eq!(p["any_handler_present"], false);
        let clients = p["clients"].as_array().unwrap();
        assert_eq!(clients.len(), 2);
        for c in clients {
            assert_eq!(c["present"], false);
        }
    }

    #[test]
    #[serial]
    fn override_present_zed_flips_any_handler() {
        std::env::set_var("CHUMP_ACP_ZED_OVERRIDE", "present");
        std::env::set_var("CHUMP_ACP_JETBRAINS_OVERRIDE", "absent");
        let p = build_acp_health_payload();
        std::env::remove_var("CHUMP_ACP_ZED_OVERRIDE");
        std::env::remove_var("CHUMP_ACP_JETBRAINS_OVERRIDE");
        assert_eq!(p["any_handler_present"], true);
        let zed = &p["clients"][0];
        assert_eq!(zed["id"], "zed");
        assert_eq!(zed["present"], true);
    }

    #[test]
    #[serial]
    fn schema_always_two_clients_with_required_fields() {
        std::env::set_var("CHUMP_ACP_ZED_OVERRIDE", "absent");
        std::env::set_var("CHUMP_ACP_JETBRAINS_OVERRIDE", "absent");
        let p = build_acp_health_payload();
        std::env::remove_var("CHUMP_ACP_ZED_OVERRIDE");
        std::env::remove_var("CHUMP_ACP_JETBRAINS_OVERRIDE");
        for c in p["clients"].as_array().unwrap() {
            for f in &[
                "id",
                "name",
                "present",
                "detected_at",
                "version",
                "binary_path",
            ] {
                assert!(c.get(f).is_some(), "client missing {}: {}", f, c);
            }
        }
        assert!(p["generated_at_iso"].is_string());
        assert!(p["acp_error"].is_null());
    }
}
