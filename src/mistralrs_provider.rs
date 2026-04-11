//! In-process inference via [mistral.rs](https://github.com/EricLBuehler/mistral.rs) (`mistralrs` crate).
//! Enable with `--features mistralrs-infer` and set `CHUMP_INFERENCE_BACKEND=mistralrs` + `CHUMP_MISTRALRS_MODEL`.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::provider::{
    CompletionResponse, Message, Provider, StopReason, Tool, ToolCall,
};
use mistralrs::{
    Function, IsqBits, RequestBuilder, TextMessageRole, Tool as MistralTool, ToolCallResponse,
    ToolChoice, ToolType, TextModelBuilder,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::local_openai::{apply_sliding_window_to_messages, strip_think_blocks};

fn map_role(role: &str) -> TextMessageRole {
    match role {
        "assistant" => TextMessageRole::Assistant,
        "system" => TextMessageRole::System,
        "tool" => TextMessageRole::Tool,
        _ => TextMessageRole::User,
    }
}

fn axon_tools_to_mistral(tools: &[Tool]) -> Vec<MistralTool> {
    tools
        .iter()
        .map(|t| {
            let parameters: Option<HashMap<String, Value>> = t
                .input_schema
                .as_object()
                .map(|o| o.iter().map(|(k, v)| (k.clone(), v.clone())).collect());
            MistralTool {
                tp: ToolType::Function,
                function: Function {
                    description: Some(t.description.clone()),
                    name: t.name.clone(),
                    parameters,
                },
            }
        })
        .collect()
}

fn tool_calls_to_axon(calls: &[ToolCallResponse]) -> Vec<ToolCall> {
    calls
        .iter()
        .map(|c| ToolCall {
            id: c.id.clone(),
            name: c.function.name.clone(),
            input: serde_json::from_str(&c.function.arguments).unwrap_or_else(|_| {
                json!({ "raw_arguments": c.function.arguments.clone() })
            }),
        })
        .collect()
}

async fn build_mistral_model(model_id: &str) -> Result<mistralrs::Model> {
    let mut b = TextModelBuilder::new(model_id);
    match std::env::var("CHUMP_MISTRALRS_ISQ_BITS")
        .unwrap_or_else(|_| "8".to_string())
        .as_str()
    {
        "4" => {
            b = b.with_auto_isq(IsqBits::Four);
        }
        "8" => {
            b = b.with_auto_isq(IsqBits::Eight);
        }
        _ => {
            b = b.with_auto_isq(IsqBits::Eight);
        }
    }
    if std::env::var("CHUMP_MISTRALRS_FORCE_CPU")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        b = b.with_force_cpu();
    }
    if std::env::var("CHUMP_MISTRALRS_LOGGING")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        b = b.with_logging();
    }
    b.build()
        .await
        .map_err(|e| anyhow!("mistral.rs model load failed: {}", e))
}

/// Returns true when env selects mistral.rs (same predicate as [`crate::env_flags::chump_inference_backend_mistralrs_env`]).
/// This module is only compiled with `--features mistralrs-infer`; without the feature, use env_flags + HTTP providers only.
pub fn mistralrs_backend_configured() -> bool {
    crate::env_flags::chump_inference_backend_mistralrs_env()
}

pub struct MistralRsProvider {
    model_id: String,
    inner: Mutex<Option<Arc<mistralrs::Model>>>,
}

impl MistralRsProvider {
    pub fn new(model_id: impl Into<String>) -> Self {
        Self {
            model_id: model_id.into(),
            inner: Mutex::new(None),
        }
    }

    async fn ensure_model(&self) -> Result<Arc<mistralrs::Model>> {
        let mut guard = self.inner.lock().await;
        if let Some(m) = guard.as_ref() {
            return Ok(Arc::clone(m));
        }
        let m = Arc::new(build_mistral_model(&self.model_id).await?);
        *guard = Some(Arc::clone(&m));
        Ok(m)
    }
}

#[async_trait]
impl Provider for MistralRsProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let model = self.ensure_model().await?;
        let messages = apply_sliding_window_to_messages(messages, system_prompt.as_deref());

        let temperature: f64 = std::env::var("CHUMP_TEMPERATURE")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0.3_f64)
            .clamp(0.0, 2.0);

        let mut req = RequestBuilder::new().set_sampler_temperature(temperature);
        if let Some(sys) = system_prompt {
            if !sys.is_empty() {
                req = req.add_message(TextMessageRole::System, sys);
            }
        }
        for m in &messages {
            req = req.add_message(map_role(&m.role), &m.content);
        }
        if let Some(mt) = max_tokens {
            req = req.set_sampler_max_len(mt as usize);
        }
        if let Some(ref tls) = tools {
            if !tls.is_empty() {
                let mistral_tools = axon_tools_to_mistral(tls);
                req = req
                    .set_tools(mistral_tools)
                    .set_tool_choice(ToolChoice::Auto);
            }
        }

        let response = model
            .send_chat_request(req)
            .await
            .map_err(|e| anyhow!("mistral.rs inference: {}", e))?;

        let choice = response
            .choices
            .into_iter()
            .next()
            .ok_or_else(|| anyhow!("mistral.rs: empty choices"))?;
        let msg = choice.message;
        let finish = choice.finish_reason.to_lowercase();

        if let Some(ref tcalls) = msg.tool_calls {
            if !tcalls.is_empty() {
                return Ok(CompletionResponse {
                    text: msg.content.clone(),
                    tool_calls: tool_calls_to_axon(tcalls),
                    stop_reason: StopReason::ToolUse,
                });
            }
        }

        let text = msg
            .content
            .map(|s| strip_think_blocks(&s))
            .filter(|s| !s.is_empty());

        let stop_reason = if finish.contains("length") {
            StopReason::MaxTokens
        } else if finish.contains("tool") {
            StopReason::ToolUse
        } else {
            StopReason::EndTurn
        };

        Ok(CompletionResponse {
            text,
            tool_calls: vec![],
            stop_reason,
        })
    }
}
