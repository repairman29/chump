//! Minimal health HTTP server when CHUMP_HEALTH_PORT is set. Serves GET /health with JSON status
//! of model, embed, memory, version, model_circuit, status (healthy/degraded), and tool_calls.

use crate::local_openai;
use crate::tool_middleware;
use crate::version;
use serde_json::json;
use std::net::SocketAddr;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

fn model_base() -> Option<String> {
    std::env::var("OPENAI_API_BASE")
        .ok()
        .filter(|s| !s.is_empty())
        .map(|s| s.trim_end_matches('/').to_string())
}

fn embed_base() -> Option<String> {
    std::env::var("CHUMP_EMBED_URL")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| Some("http://127.0.0.1:18765".to_string()))
        .map(|s| s.trim_end_matches('/').to_string())
}

async fn probe_model() -> &'static str {
    if crate::env_flags::chump_inference_backend_mistralrs_env() {
        return "ok";
    }
    let base = match model_base() {
        Some(b) => b,
        None => return "n/a",
    };
    let url = format!("{}/models", base);
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(2))
        .build()
        .ok();
    let client = match client {
        Some(c) => c,
        None => return "down",
    };
    match client.get(&url).send().await {
        Ok(r) if r.status().is_success() => "ok",
        _ => "down",
    }
}

async fn probe_embed() -> &'static str {
    let base = match embed_base() {
        Some(b) => b,
        None => return "n/a",
    };
    let url = format!("{}/health", base);
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(2))
        .build()
        .ok();
    let client = match client {
        Some(c) => c,
        None => return "down",
    };
    match client.get(&url).send().await {
        Ok(r) if r.status().is_success() => "ok",
        _ => "down",
    }
}

fn probe_memory() -> &'static str {
    if crate::memory_db::db_available() {
        "ok"
    } else {
        "down"
    }
}

pub async fn run(port: u16) {
    let addr: SocketAddr = ([0, 0, 0, 0], port).into();
    let listener = match TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("chump: health server bind {}: {}", port, e);
            return;
        }
    };
    eprintln!(
        "chump: health server listening on http://0.0.0.0:{}/health",
        port
    );
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(conn) => conn,
            Err(_) => continue,
        };
        tokio::spawn(handle(stream));
    }
}

async fn handle(stream: tokio::net::TcpStream) {
    let (read_half, mut writer) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut first_line = String::new();
    if reader.read_line(&mut first_line).await.is_err() {
        return;
    }
    let is_health = first_line.starts_with("GET /health") || first_line.starts_with("GET /health ");
    if !is_health {
        let _ = writer
            .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            .await;
        return;
    }
    let model = probe_model().await;
    let embed = probe_embed().await;
    let memory = probe_memory();
    let model_base_url = model_base();
    let model_circuit = model_base_url
        .as_ref()
        .map(|b| local_openai::model_circuit_state(b))
        .unwrap_or("n/a");
    let status = if model == "down" || model_circuit == "open" {
        "degraded"
    } else {
        "healthy"
    };
    let tool_calls = tool_middleware::tool_call_counts();
    let tool_calls_json: serde_json::Map<String, serde_json::Value> = tool_calls
        .into_iter()
        .map(|(k, v)| (k, serde_json::Value::Number(serde_json::Number::from(v))))
        .collect();
    let top_surprising: Vec<serde_json::Value> = vec![];

    let graph_triples = crate::memory_graph::triple_count().unwrap_or(0);
    let lesson_count = crate::counterfactual::lesson_count().unwrap_or(0);
    let failure_pats = crate::counterfactual::failure_patterns(5)
        .unwrap_or_default()
        .into_iter()
        .map(|(typ, cnt)| json!({"type": typ, "count": cnt}))
        .collect::<Vec<_>>();

    let bb = crate::blackboard::global();
    let phi_metrics = crate::phi_proxy::compute_phi();

    let consciousness_dashboard = json!({
        "surprise": {
            "ema": 0.0,
            "total": 0,
            "high_pct": 0.0,
            "top_surprising_tools": top_surprising,
        },
        "memory_graph": {
            "triples": graph_triples,
            "available": crate::memory_graph::graph_available(),
        },
        "blackboard": {
            "entries": bb.entry_count(),
            "broadcast_count": bb.cross_read_entry_count(),
        },
        "counterfactual": {
            "lessons": lesson_count,
            "failure_patterns": failure_pats,
        },
        "precision": {
            "regime": crate::precision_controller::current_regime().to_string(),
            "model_tier": crate::precision_controller::recommended_model_tier().to_string(),
            "escalation_rate": crate::precision_controller::escalation_rate(),
            "token_budget_remaining": crate::precision_controller::token_budget_remaining(),
            "tool_budget_remaining": crate::precision_controller::tool_call_budget_remaining(),
            "recommended_max_tool_calls": crate::precision_controller::recommended_max_tool_calls(),
            "recommended_max_delegate_parallel": crate::precision_controller::recommended_max_delegate_parallel(),
            "belief_tool_budget": crate::env_flags::chump_belief_tool_budget(),
            "task_uncertainty": (crate::belief_state::task_belief().uncertainty() * 1000.0).round() / 1000.0,
            "context_exploration_fraction": (crate::precision_controller::context_exploration_budget() * 1000.0).round() / 1000.0,
            "effective_tool_timeout_secs": crate::neuromodulation::effective_tool_timeout_secs(
                crate::tool_middleware::DEFAULT_TOOL_TIMEOUT_SECS,
            ),
        },
        "phi": {
            "proxy": phi_metrics.phi_proxy,
            "coupling": phi_metrics.coupling_score,
            "cross_read_pct": phi_metrics.cross_read_utilization * 100.0,
            "active_pairs": phi_metrics.active_coupling_pairs,
            "entropy": phi_metrics.information_flow_entropy,
        },
        "belief_state": crate::belief_state::metrics_json(),
        "neuromodulation": crate::neuromodulation::metrics_json(),
        "speculative_batch": crate::speculative_execution::last_speculative_metrics_json(),
    });
    let recent_tool_calls = crate::introspect_tool::recent_tool_calls_json(15);

    let inference_backend = if crate::env_flags::chump_inference_backend_mistralrs_env() {
        "mistralrs"
    } else {
        "openai_compatible"
    };
    let body = json!({
        "model": model,
        "inference_backend": inference_backend,
        "llm_last_completion": crate::llm_backend_metrics::snapshot_last_json(),
        "llm_completion_totals": crate::llm_backend_metrics::snapshot_totals_json(),
        "embed": embed,
        "memory": memory,
        "version": version::chump_version(),
        "model_circuit": model_circuit,
        "status": status,
        "tool_max_in_flight": tool_middleware::max_in_flight_for_health(),
        "tool_rate_limit": tool_middleware::rate_limit_config_for_health(),
        "tool_calls": tool_calls_json,
        "recent_tool_calls": recent_tool_calls,
        "consciousness_dashboard": consciousness_dashboard,
    });
    let body_str = body.to_string();
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body_str.len(),
        body_str
    );
    let _ = writer.write_all(response.as_bytes()).await;
    let _ = writer.flush().await;
}
