//! OpenAI-compatible provider that uses a configurable base URL (e.g. vLLM-MLX at http://localhost:8000/v1).
//! Supports retries with backoff, optional fallback URL (CHUMP_FALLBACK_API_BASE), and a simple circuit breaker.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::provider::{
    CompletionResponse, Message, Provider, StopReason, Tool, ToolCall,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::time::sleep;

const RETRY_DELAYS_MS: &[u64] = &[0, 1000, 2000];
const CIRCUIT_FAILURE_THRESHOLD: u32 = 3;
const CIRCUIT_COOLDOWN_SECS: u64 = 30;

struct CircuitState {
    failures: u32,
    open_until: Option<Instant>,
}

fn circuit_state() -> &'static Mutex<HashMap<String, CircuitState>> {
    static CELL: std::sync::OnceLock<Mutex<HashMap<String, CircuitState>>> = std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn is_transient_error(err: &anyhow::Error) -> bool {
    let s = err.to_string();
    s.contains("connection")
        || s.contains("timed out")
        || s.contains("Connection reset")
        || s.contains("500")
        || s.contains("502")
        || s.contains("503")
        || s.contains("504")
}

pub struct LocalOpenAIProvider {
    base_url: String,
    fallback_base_url: Option<String>,
    api_key: String,
    model: String,
    client: reqwest::Client,
}

impl LocalOpenAIProvider {
    pub fn new(base_url: String, api_key: String, model: String) -> Self {
        Self::with_fallback(base_url, None, api_key, model)
    }

    /// Build with optional fallback URL (e.g. from CHUMP_FALLBACK_API_BASE). If primary fails after retries, one attempt is made to the fallback.
    pub fn with_fallback(
        base_url: String,
        fallback_base_url: Option<String>,
        api_key: String,
        model: String,
    ) -> Self {
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            fallback_base_url: fallback_base_url.map(|u| u.trim_end_matches('/').to_string()),
            api_key,
            model,
            client: reqwest::Client::new(),
        }
    }
}

#[async_trait]
impl Provider for LocalOpenAIProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let mut complete_message: Vec<Value> = Vec::new();

        if let Some(sys_prompt) = system_prompt {
            complete_message.push(json!({
                "role": "system",
                "content": sys_prompt
            }));
        }

        for m in &messages {
            complete_message.push(json!({
                "role": m.role,
                "content": m.content
            }));
        }

        let mut body = json!({
            "model": self.model,
            "messages": complete_message,
        });

        if let Some(max_tokens) = max_tokens {
            body["max_tokens"] = json!(max_tokens);
        }

        if let Some(tools) = tools {
            let openai_tools: Vec<Value> = tools
                .iter()
                .map(|t| {
                    json!({
                        "type": "function",
                        "function": {
                            "name": t.name,
                            "description": t.description,
                            "parameters": t.input_schema,
                        }
                    })
                })
                .collect();
            body["tools"] = json!(openai_tools);
            // Hint for servers that support structured tool output (e.g. vLLM with --enable-auto-tool-choice).
            body["tool_choice"] = json!("auto");
        }

        let mut last_err = None;
        for &delay_ms in RETRY_DELAYS_MS {
            if delay_ms > 0 {
                sleep(Duration::from_millis(delay_ms)).await;
            }
            match self.try_one_request(&self.base_url, &body).await {
                Ok(r) => {
                    self.circuit_success(&self.base_url);
                    return Ok(r);
                }
                Err(e) => {
                    last_err = Some(anyhow!("{}", e));
                    if !is_transient_error(&e) {
                        return Err(e);
                    }
                    self.circuit_failure(&self.base_url);
                }
            }
        }
        if let Some(ref fallback) = self.fallback_base_url {
            if let Ok(r) = self.try_one_request(fallback, &body).await {
                self.circuit_success(fallback);
                return Ok(r);
            }
            self.circuit_failure(fallback);
        }
        Err(last_err.unwrap_or_else(|| anyhow!("model temporarily unavailable")))
    }
}

impl LocalOpenAIProvider {
    fn circuit_success(&self, base: &str) {
        if let Ok(mut guard) = circuit_state().lock() {
            guard.remove(base);
        }
    }

    fn circuit_failure(&self, base: &str) {
        if let Ok(mut guard) = circuit_state().lock() {
            let state = guard.entry(base.to_string()).or_insert(CircuitState {
                failures: 0,
                open_until: None,
            });
            state.failures += 1;
            if state.failures >= CIRCUIT_FAILURE_THRESHOLD {
                state.open_until = Some(Instant::now() + Duration::from_secs(CIRCUIT_COOLDOWN_SECS));
            }
        }
    }

    fn circuit_open(&self, base: &str) -> bool {
        if let Ok(guard) = circuit_state().lock() {
            if let Some(s) = guard.get(base) {
                if let Some(until) = s.open_until {
                    if Instant::now() < until {
                        return true;
                    }
                }
            }
        }
        false
    }

    async fn try_one_request(
        &self,
        base_url: &str,
        body: &Value,
    ) -> Result<CompletionResponse> {
        if self.circuit_open(base_url) {
            return Err(anyhow!(
                "model temporarily unavailable (circuit open for {}s)",
                CIRCUIT_COOLDOWN_SECS
            ));
        }
        let url = format!("{}/chat/completions", base_url);
        let is_local = base_url.contains("127.0.0.1") || base_url.contains("localhost");
        let skip_auth = is_local
            && (self.api_key.is_empty()
                || self.api_key == "not-needed"
                || self.api_key == "token-abc123");
        let mut req = self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .json(body);
        if !skip_auth {
            req = req.header("Authorization", format!("Bearer {}", self.api_key));
        }
        let response = req.send().await?;
        let status = response.status();
        if !status.is_success() {
            let error_text = response.text().await?;
            return Err(anyhow!("Local API error {}: {}", status, error_text));
        }
        let api_response: LocalOpenAIResponse = response.json().await?;
        let choice = api_response
            .choices
            .first()
            .ok_or_else(|| anyhow!("No choices in response"))?;

        let text = choice.message.content.clone();
        let tool_calls = if let Some(calls) = &choice.message.tool_calls {
            calls
                .iter()
                .map(|tc| {
                    let input = match serde_json::from_str(&tc.function.arguments) {
                        Ok(v) => v,
                        Err(e) => {
                            eprintln!(
                                "chump: malformed tool JSON for {}: {} — args: [REDACTED]",
                                tc.function.name, e
                            );
                            json!({})
                        }
                    };
                    ToolCall {
                        id: tc.id.clone(),
                        name: tc.function.name.clone(),
                        input,
                    }
                })
                .collect()
        } else {
            vec![]
        };

        let finish = choice.finish_reason.as_deref().unwrap_or("stop");
        let stop_reason = match finish {
            "tool_calls" => StopReason::ToolUse,
            "stop" => StopReason::EndTurn,
            "length" => StopReason::MaxTokens,
            "content_filter" => StopReason::ContentFilter,
            _ => StopReason::EndTurn,
        };

        Ok(CompletionResponse {
            text,
            tool_calls,
            stop_reason,
        })
    }
}

#[derive(Debug, Deserialize)]
struct LocalOpenAIResponse {
    choices: Vec<LocalChoice>,
}

#[derive(Debug, Deserialize)]
struct LocalChoice {
    message: LocalResponseMessage,
    finish_reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct LocalResponseMessage {
    content: Option<String>,
    tool_calls: Option<Vec<LocalToolCall>>,
}

#[derive(Debug, Deserialize)]
struct LocalToolCall {
    id: String,
    function: LocalFunctionCall,
}

#[derive(Debug, Deserialize)]
struct LocalFunctionCall {
    name: String,
    arguments: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use axonerai::provider::Message;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn complete_parses_valid_response_and_tool_calls() {
        let mock = MockServer::start().await;
        let body = serde_json::json!({
            "choices": [{
                "message": {
                    "content": "Sure, I'll run that.",
                    "tool_calls": [{
                        "id": "call_1",
                        "function": {
                            "name": "run_cli",
                            "arguments": "{\"command\": \"ls -la\"}"
                        }
                    }]
                },
                "finish_reason": "tool_calls"
            }]
        });
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&body))
            .mount(&mock)
            .await;

        let provider = LocalOpenAIProvider::new(
            mock.uri().to_string(),
            "not-needed".to_string(),
            "test".to_string(),
        );
        let messages = vec![Message {
            role: "user".to_string(),
            content: "List files".to_string(),
        }];
        let out = provider.complete(messages, None, None, None).await.unwrap();
        assert_eq!(out.text.as_deref(), Some("Sure, I'll run that."));
        assert_eq!(out.tool_calls.len(), 1);
        assert_eq!(out.tool_calls[0].id, "call_1");
        assert_eq!(out.tool_calls[0].name, "run_cli");
        assert_eq!(
            out.tool_calls[0].input.get("command").and_then(|c| c.as_str()),
            Some("ls -la")
        );
    }

    #[tokio::test]
    async fn complete_malformed_tool_args_maps_to_empty_object() {
        let mock = MockServer::start().await;
        let body = serde_json::json!({
            "choices": [{
                "message": {
                    "content": null,
                    "tool_calls": [{
                        "id": "call_2",
                        "function": {
                            "name": "run_cli",
                            "arguments": "not valid json at all"
                        }
                    }]
                },
                "finish_reason": "tool_calls"
            }]
        });
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&body))
            .mount(&mock)
            .await;

        let provider = LocalOpenAIProvider::new(
            mock.uri().to_string(),
            "not-needed".to_string(),
            "test".to_string(),
        );
        let messages = vec![Message {
            role: "user".to_string(),
            content: "run something".to_string(),
        }];
        let out = provider.complete(messages, None, None, None).await.unwrap();
        assert_eq!(out.tool_calls.len(), 1);
        assert_eq!(out.tool_calls[0].name, "run_cli");
        assert!(out.tool_calls[0].input.is_object());
        assert!(out.tool_calls[0].input.as_object().unwrap().is_empty());
    }
}
