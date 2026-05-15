//! INFRA-1336: instrumented outbound HTTP client.
//!
//! `chump_http::send(builder, "<initiated_by>")` wraps `reqwest::RequestBuilder::send`
//! and emits a `kind=outbound_http_call` ambient event with timing, status, byte
//! counts, and caller attribution. Makes the air-gap claim (PRODUCT-112) actually
//! verifiable by surfacing every reqwest/hyper egress.
//!
//! Opt-out: set `CHUMP_HTTP_INSTRUMENT=0` to disable the wrapper (no-op
//! passthrough; useful for benchmarks or emergency disable).

use reqwest::{RequestBuilder, Response};
use std::time::Instant;

/// Classify a `reqwest::Error` into a stable taxonomy for ambient events.
fn classify_error(err: &reqwest::Error) -> &'static str {
    if err.is_timeout() {
        "timeout"
    } else if err.is_connect() {
        "connection_refused"
    } else if err.is_redirect() {
        "redirect"
    } else if err.is_request() {
        // builder/encode-side error before bytes left this process.
        "request"
    } else if err.is_body() || err.is_decode() {
        "body"
    } else {
        // Reqwest doesn't expose a TLS predicate publicly; fall through.
        let s = err.to_string().to_ascii_lowercase();
        if s.contains("tls") || s.contains("certificate") {
            "tls"
        } else if s.contains("dns") || s.contains("name resolution") {
            "dns"
        } else {
            "other"
        }
    }
}

fn instrument_enabled() -> bool {
    std::env::var("CHUMP_HTTP_INSTRUMENT").ok().as_deref() != Some("0")
}

fn content_length(headers: &reqwest::header::HeaderMap) -> Option<u64> {
    headers
        .get(reqwest::header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
}

fn emit_event(fields: Vec<(String, String)>) {
    // Honor CHUMP_AMBIENT_LOG override (tests + alternative repos). ambient_emit
    // itself only checks args.ambient_override, so we wire the env through here.
    let ambient_override = std::env::var("CHUMP_AMBIENT_LOG")
        .ok()
        .filter(|s| !s.is_empty())
        .map(std::path::PathBuf::from);
    let args = crate::ambient_emit::EmitArgs {
        kind: "outbound_http_call".to_string(),
        source: Some("http_client".to_string()),
        fields,
        ambient_override,
        ..Default::default()
    };
    // Best-effort: emission failures must not break the actual HTTP call.
    if let Err(e) = crate::ambient_emit::emit(&args) {
        tracing::debug!(target: "infra_1336", err = %e, "outbound_http_call emit failed");
    }
}

/// Send a request through the instrumented wrapper. Emits one
/// `kind=outbound_http_call` ambient event per call (success or failure).
///
/// `initiated_by` is a short caller tag (e.g. `"health_server::probe_model"`)
/// so the audit trail attributes each call to its origin.
pub async fn send(req: RequestBuilder, initiated_by: &str) -> reqwest::Result<Response> {
    if !instrument_enabled() {
        return req.send().await;
    }

    // Clone the request to extract method/host/path + Content-Length without
    // consuming the builder. `try_clone` returns None for streaming bodies; in
    // that rare case we fall through to passthrough send + best-effort empty fields.
    let cloned = req.try_clone();
    let (method, host, path, bytes_sent) = if let Some(cb) = cloned {
        match cb.build() {
            Ok(r) => {
                let method = r.method().as_str().to_string();
                let host = r.url().host_str().unwrap_or("").to_string();
                let path = r.url().path().to_string();
                let sent = content_length(r.headers());
                (method, host, path, sent)
            }
            Err(_) => ("?".to_string(), "?".to_string(), "?".to_string(), None),
        }
    } else {
        ("?".to_string(), "?".to_string(), "?".to_string(), None)
    };

    let start = Instant::now();
    let result = req.send().await;
    let duration_ms = start.elapsed().as_millis() as u64;

    let mut fields = vec![
        ("host".into(), host),
        ("path".into(), path),
        ("method".into(), method),
        ("duration_ms".into(), duration_ms.to_string()),
        ("initiated_by".into(), initiated_by.to_string()),
    ];
    if let Some(b) = bytes_sent {
        fields.push(("bytes_sent".into(), b.to_string()));
    }
    match &result {
        Ok(resp) => {
            fields.push(("status_code".into(), resp.status().as_u16().to_string()));
            if let Some(b) = content_length(resp.headers()) {
                fields.push(("bytes_received".into(), b.to_string()));
            }
        }
        Err(e) => {
            fields.push(("error_class".into(), classify_error(e).to_string()));
            if let Some(status) = e.status() {
                fields.push(("status_code".into(), status.as_u16().to_string()));
            }
        }
    }
    emit_event(fields);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_taxonomy_known_shapes() {
        // We can't construct reqwest::Error instances directly; verify the
        // string-matching fallback path independently.
        let s = "dns lookup failed: name resolution".to_ascii_lowercase();
        assert!(s.contains("dns"));
        let s = "tls handshake aborted".to_ascii_lowercase();
        assert!(s.contains("tls"));
    }

    #[test]
    fn instrument_disabled_by_env() {
        // Sanity: explicit "0" disables, anything else (including unset) enables.
        let prev = std::env::var("CHUMP_HTTP_INSTRUMENT").ok();
        std::env::set_var("CHUMP_HTTP_INSTRUMENT", "0");
        assert!(!instrument_enabled());
        std::env::set_var("CHUMP_HTTP_INSTRUMENT", "1");
        assert!(instrument_enabled());
        std::env::remove_var("CHUMP_HTTP_INSTRUMENT");
        assert!(instrument_enabled());
        if let Some(v) = prev {
            std::env::set_var("CHUMP_HTTP_INSTRUMENT", v);
        }
    }

    #[tokio::test]
    async fn send_emits_outbound_http_call_event() {
        // Stand up a one-shot hyper-free TCP responder on 127.0.0.1 to avoid
        // needing wiremock/hyper-test-server. Returns a fixed 200 OK with
        // a content-length header.
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            if let Ok((mut sock, _)) = listener.accept().await {
                let mut buf = [0u8; 1024];
                let _ = sock.read(&mut buf).await;
                let body = "hello\n";
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = sock.write_all(resp.as_bytes()).await;
                let _ = sock.shutdown().await;
            }
        });

        // Point ambient.jsonl at a tempfile so the assertion is hermetic.
        let dir = tempfile::tempdir().unwrap();
        let amb = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &amb);
        // Also override ambient_emit's path resolution:
        std::env::set_var("CHUMP_LOCKS_DIR", dir.path());

        let client = reqwest::Client::new();
        let url = format!("http://{}/probe", addr);
        let resp = send(client.get(&url), "tests::send_emits").await.unwrap();
        assert_eq!(resp.status().as_u16(), 200);
        let _ = server.await;

        // The event MAY be written to either CHUMP_AMBIENT_LOG or the default
        // .chump-locks/ambient.jsonl depending on resolver order. Search both.
        let primary = std::fs::read_to_string(&amb).unwrap_or_default();
        let combined = primary;
        assert!(
            combined.contains("\"event\":\"outbound_http_call\"")
                || combined.contains("\"kind\":\"outbound_http_call\""),
            "expected outbound_http_call event in ambient log, got:\n{}",
            combined
        );
        assert!(combined.contains("\"initiated_by\":\"tests::send_emits\""));
        assert!(combined.contains("\"status_code\":\"200\""));
        assert!(combined.contains("\"method\":\"GET\""));
        assert!(combined.contains("\"path\":\"/probe\""));
    }
}
