//! Minimal health HTTP server when CHUMP_HEALTH_PORT is set. Serves GET /health with JSON status of model, embed, memory, version.

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
    eprintln!("chump: health server listening on http://0.0.0.0:{}/health", port);
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
        let _ = writer.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n").await;
        return;
    }
    let model = probe_model().await;
    let embed = probe_embed().await;
    let memory = probe_memory();
    let body = json!({
        "model": model,
        "embed": embed,
        "memory": memory,
        "version": version::chump_version(),
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
